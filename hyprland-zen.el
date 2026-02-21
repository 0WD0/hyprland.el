;;; hyprland-zen.el --- Zen browser bridge for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Experimental Zen tab bridge over a line-delimited JSON host process.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'hyprland-base)
(require 'hyprland-consult)

(defgroup hyprland-zen nil
  "Zen browser integration for hyprland.el."
  :group 'hyprland)

(defcustom hyprland-zen-host-command '("hyprland-zen-native-host" "--line-stdio")
  "Command list used to launch the Zen native host bridge.

The host process exchanges one JSON object per line with Emacs."
  :type '(repeat string)
  :group 'hyprland-zen)

(defcustom hyprland-zen-auto-refresh-on-start t
  "When non-nil, send an initial tab snapshot request after start."
  :type 'boolean
  :group 'hyprland-zen)

(defcustom hyprland-zen-jump-to-window-on-tab-switch t
  "When non-nil, tab switch also focuses corresponding Hyprland window.

This uses browser-side window focus first, and keeps a best-effort mapping from
browser window ids to Hyprland addresses for explicit `hyprland-jump' fallback."
  :type 'boolean
  :group 'hyprland-zen)

(defcustom hyprland-zen-window-class-regexp "\\(zen\\|firefox\\|chromium\\)"
  "Regexp used to validate active Hyprland window class for tab-window mapping."
  :type '(choice (const :tag "Disabled" nil) regexp)
  :group 'hyprland-zen)

(defcustom hyprland-zen-preview-key '(:debounce 0.15 any)
  "Preview trigger configuration passed to `consult--read' for tab selection.

Examples:

- `any': preview on every candidate change.
- `(:debounce 0.3 any)': delayed auto preview.
- `M-.': manual preview trigger.
- nil: disable live preview."
  :type 'sexp
  :group 'hyprland-zen)

(defcustom hyprland-zen-initial-sync-timeout 1.5
  "Seconds to wait for initial tab snapshot when local store is empty."
  :type 'number
  :group 'hyprland-zen)

(defvar hyprland-zen--tabs (make-hash-table :test #'equal)
  "Zen tab store keyed by `browser/profile/tab_id'.")

(defvar hyprland-zen--workspaces (make-hash-table :test #'equal)
  "Zen workspace store keyed by `browser/profile/workspace_id'.")

(defvar hyprland-zen--browser-window->hyprland-address (make-hash-table :test #'equal)
  "Best-effort map from browser window id to Hyprland address.")

(defvar hyprland-zen--process nil)
(defvar hyprland-zen--fragment "")
(defvar hyprland-zen--preview-tab-id nil)

(defvar hyprland-zen-after-refresh-hook nil
  "Hook run after Zen tab store changes.")

(declare-function hyprland-jump "hyprland-sync" (address))
(declare-function hyprland-consult--display-preview "hyprland-consult" (payload))
(declare-function hyprland-consult--cleanup-preview "hyprland-consult" ())
(declare-function consult--read "consult" (candidates &rest options))
(declare-function consult--lookup-cdr "consult" (selected candidates input &rest _))

(defun hyprland-zen--usable-executable-p (path)
  "Return non-nil when PATH points to a non-empty executable file."
  (when (and (stringp path) (file-executable-p path) (file-regular-p path))
    (let ((attrs (file-attributes path 'string)))
      (and attrs (> (file-attribute-size attrs) 0)))))

(defun hyprland-zen--resolve-host-command ()
  "Resolve configured host command, supporting local repo fallback."
  (when-let* ((cmd hyprland-zen-host-command)
              (head (car cmd)))
    (let ((from-path (executable-find head)))
      (cond
       ((hyprland-zen--usable-executable-p from-path)
        (cons from-path (cdr cmd)))
       ((hyprland-zen--usable-executable-p head)
        cmd)
       (t
        (let* ((lib (or load-file-name (locate-library "hyprland-zen")))
               (root (and lib (file-name-directory lib)))
               (local (and root (expand-file-name "browser/native-host/hyprland-zen-native-host" root))))
          (when (hyprland-zen--usable-executable-p local)
            (cons local (cdr cmd)))))))))

(defun hyprland-zen--field (alist key)
  "Return ALIST field KEY, allowing both symbol and string keys."
  (or (alist-get key alist)
      (alist-get (symbol-name key) alist nil nil #'string=)))

(defun hyprland-zen--truthy-p (value)
  "Return non-nil when VALUE should be interpreted as true."
  (not (or (null value)
           (eq value :false)
           (eq value 0)
           (equal value "0")
           (equal value "false"))))

(defun hyprland-zen--string (value &optional fallback)
  "Return VALUE as string, or FALLBACK when empty/nil."
  (let ((out (if (null value) "" (string-trim (format "%s" value)))))
    (if (string-empty-p out)
        (or fallback "")
      out)))

(defun hyprland-zen--window-id (tab)
  "Return normalized browser window id string from TAB payload."
  (let ((value (or (hyprland-zen--field tab 'window_id)
                   (hyprland-zen--field tab 'windowId))))
    (let ((out (hyprland-zen--string value)))
      (unless (string-empty-p out)
        out))))

(defun hyprland-zen--active-hyprland-window-address ()
  "Return active Hyprland window address when class matches zen browser regexp."
  (condition-case _err
      (when-let* ((active (hyprland--hyprctl-json "activewindow"))
                  (address-raw (hyprland-zen--field active 'address))
                  (address (hyprland--normalize-address address-raw)))
        (let* ((class (downcase (hyprland-zen--string (hyprland-zen--field active 'class))))
               (ok (or (null hyprland-zen-window-class-regexp)
                       (string-match-p hyprland-zen-window-class-regexp class))))
          (when ok address)))
    (error nil)))

(defun hyprland-zen--remember-window-address (window-id &optional address)
  "Store mapping from browser WINDOW-ID to Hyprland ADDRESS.

When ADDRESS is nil, use current active Hyprland window address."
  (when-let* ((wid (hyprland-zen--string window-id))
              (_ (not (string-empty-p wid)))
              (resolved (or address (hyprland-zen--active-hyprland-window-address))))
    (puthash wid resolved hyprland-zen--browser-window->hyprland-address)
    resolved))

(defun hyprland-zen--schedule-window-address-refresh (window-id)
  "Refresh browser WINDOW-ID -> Hyprland address mapping shortly after focus."
  (when (and hyprland-zen-jump-to-window-on-tab-switch
             (stringp window-id)
             (not (string-empty-p window-id)))
    (run-at-time 0.12 nil #'hyprland-zen--remember-window-address window-id)))

(defun hyprland-zen--jump-to-known-window (window-id)
  "Jump to mapped Hyprland window for browser WINDOW-ID.

Return non-nil when jump was dispatched."
  (when (and hyprland-zen-jump-to-window-on-tab-switch
             (fboundp 'hyprland-jump)
             (stringp window-id)
             (not (string-empty-p window-id)))
    (when-let* ((address (gethash window-id hyprland-zen--browser-window->hyprland-address)))
      (condition-case _err
          (progn
            (hyprland-jump address)
            t)
        (error nil)))))

(defun hyprland-zen--decode-image-data-url (data-url)
  "Decode DATA-URL image string into plist `(:bytes :type)'."
  (when (and (stringp data-url)
             (string-match "\\`data:image/\\([A-Za-z0-9.+-]+\\);base64,\\(.+\\)\\'" data-url))
    (let* ((raw-type (downcase (match-string 1 data-url)))
           (image-type (pcase raw-type
                         ((or "jpg" "jpeg") 'jpeg)
                         ("png" 'png)
                         (_ (intern raw-type))))
           (body (match-string 2 data-url)))
      (condition-case _err
          (list :bytes (base64-decode-string body)
                :type image-type)
        (error nil)))))

(defun hyprland-zen--display-preview-message (message)
  "Display textual preview MESSAGE using shared Consult preview UI."
  (hyprland-consult--display-preview (list :ok nil :message message)))

(defun hyprland-zen--display-preview-data-url (data-url)
  "Display image preview from DATA-URL using shared Consult preview UI."
  (if-let* ((decoded (hyprland-zen--decode-image-data-url data-url)))
      (hyprland-consult--display-preview
       (list :ok t
             :image-bytes (plist-get decoded :bytes)
             :image-type (plist-get decoded :type)))
    (hyprland-zen--display-preview-message "Tab preview decode failed")))

(defun hyprland-zen--preview-state (action cand)
  "Consult state callback for Zen tab preview.

ACTION and CAND follow Consult's :state contract."
  (pcase action
    ('setup nil)
    ('preview
     (if (not cand)
         (hyprland-zen--display-preview-message "No tab candidate")
       (let ((tab-id (hyprland-zen--string (hyprland-zen--field cand 'tab_id))))
         (if (string-empty-p tab-id)
             (hyprland-zen--display-preview-message "Candidate missing tab id")
           (setq hyprland-zen--preview-tab-id tab-id)
           (hyprland-zen--display-preview-message "Loading tab preview...")
           (condition-case err
               (hyprland-zen--send `((op . "capture-tab")
                                     (tab_id . ,tab-id)))
             (error
              (hyprland-zen--display-preview-message
               (format "Preview request failed: %s" (error-message-string err)))))))))
    ((or 'exit 'return)
     (setq hyprland-zen--preview-tab-id nil)
     (hyprland-consult--cleanup-preview))))

(defun hyprland-zen--wait-for-tabs (&optional timeout)
  "Wait up to TIMEOUT seconds for tab store to populate, then return tabs list."
  (let ((deadline (+ (float-time) (or timeout hyprland-zen-initial-sync-timeout)))
        tabs)
    (while (and (null (setq tabs (hyprland-zen-tabs)))
                (hyprland-zen-running-p)
                (< (float-time) deadline))
      (accept-process-output hyprland-zen--process 0.1))
    tabs))

(defun hyprland-zen--ensure-tabs-ready ()
  "Ensure host is running and attempt to populate tab snapshot.

Return current tab list (possibly empty)."
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start))
  (or (hyprland-zen-tabs)
      (progn
        (hyprland-zen-refresh)
        (hyprland-zen-refresh-workspaces)
        (hyprland-zen--wait-for-tabs))))

(defun hyprland-zen--ensure-workspaces-ready ()
  "Ensure host is running and attempt to populate workspace snapshot.

Return current workspace list (possibly empty)."
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start))
  (or (hyprland-zen-workspaces)
      (progn
        (hyprland-zen-refresh-workspaces)
        (let ((deadline (+ (float-time) hyprland-zen-initial-sync-timeout))
              spaces)
          (while (and (null (setq spaces (hyprland-zen-workspaces)))
                      (hyprland-zen-running-p)
                      (< (float-time) deadline))
            (accept-process-output hyprland-zen--process 0.1))
          spaces))))

(defun hyprland-zen--workspace-id-from-tab (tab)
  "Extract workspace id from TAB payload."
  (let* ((workspace (hyprland-zen--field tab 'workspace))
         (raw (or (hyprland-zen--field tab 'workspace_id)
                  (hyprland-zen--field tab 'workspaceId)
                  (when (listp workspace)
                    (or (hyprland-zen--field workspace 'id)
                        (hyprland-zen--field workspace 'workspace_id)))
                  (unless (listp workspace) workspace))))
    (hyprland-zen--string raw "default")))

(defun hyprland-zen--workspace-name-from-tab (tab)
  "Extract workspace display name from TAB payload."
  (let* ((workspace (hyprland-zen--field tab 'workspace))
         (raw (or (hyprland-zen--field tab 'workspace_name)
                  (hyprland-zen--field tab 'workspaceName)
                  (when (listp workspace)
                    (or (hyprland-zen--field workspace 'name)
                        (hyprland-zen--field workspace 'title)
                        (hyprland-zen--field workspace 'workspace_name))))))
    (hyprland-zen--string raw "default")))

(defun hyprland-zen--normalize-workspace (workspace)
  "Normalize WORKSPACE alist shape used by the workspace store."
  (let* ((browser (hyprland-zen--string (hyprland-zen--field workspace 'browser) "zen"))
         (profile (hyprland-zen--string (hyprland-zen--field workspace 'profile) "default"))
         (workspace-id
          (hyprland-zen--string
           (or (hyprland-zen--field workspace 'workspace_id)
               (hyprland-zen--field workspace 'workspaceId)
               (hyprland-zen--field workspace 'id)
               (hyprland-zen--field workspace 'workspace))
           "default"))
         (name
          (hyprland-zen--string
           (or (hyprland-zen--field workspace 'name)
               (hyprland-zen--field workspace 'title)
               workspace-id)
           "default")))
    (list
     (cons 'browser browser)
     (cons 'profile profile)
     (cons 'workspace_id workspace-id)
     (cons 'name name)
     (cons 'active (hyprland-zen--truthy-p (hyprland-zen--field workspace 'active)))
     (cons 'icon (hyprland-zen--string (hyprland-zen--field workspace 'icon)))
     (cons 'color (hyprland-zen--string (hyprland-zen--field workspace 'color)))
     (cons 'last_seen (hyprland-zen--field workspace 'last_seen)))))

(defun hyprland-zen--workspace-key (workspace)
  "Return stable key for WORKSPACE alist."
  (when-let* ((normalized (hyprland-zen--normalize-workspace workspace)))
    (format "%s/%s/%s"
            (hyprland-zen--field normalized 'browser)
            (hyprland-zen--field normalized 'profile)
            (hyprland-zen--field normalized 'workspace_id))))

(defun hyprland-zen--normalize-tab (tab)
  "Normalize TAB alist shape used by the Zen store."
  (let* ((tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id)))
         (browser (hyprland-zen--string (hyprland-zen--field tab 'browser) "zen"))
         (profile (hyprland-zen--string (hyprland-zen--field tab 'profile) "default"))
         (window-id (hyprland-zen--string (hyprland-zen--window-id tab)))
         (cookie-store (hyprland-zen--string (or (hyprland-zen--field tab 'cookie_store_id)
                                                 (hyprland-zen--field tab 'cookieStoreId))
                                             "default"))
         (sync-group (hyprland-zen--string (hyprland-zen--field tab 'sync_group)
                                           (format "container:%s" cookie-store)))
         (workspace-id (hyprland-zen--workspace-id-from-tab tab))
         (workspace-name (hyprland-zen--workspace-name-from-tab tab)))
    (unless (string-empty-p tab-id)
      (list
       (cons 'browser browser)
       (cons 'profile profile)
       (cons 'sync_group sync-group)
       (cons 'cookie_store_id cookie-store)
       (cons 'workspace_id workspace-id)
       (cons 'workspace_name workspace-name)
       (cons 'tab_id tab-id)
       (cons 'window_id window-id)
       (cons 'url (hyprland-zen--string (hyprland-zen--field tab 'url)))
       (cons 'title (hyprland-zen--string (hyprland-zen--field tab 'title) "<untitled tab>"))
       (cons 'audible (hyprland-zen--truthy-p (hyprland-zen--field tab 'audible)))
       (cons 'pinned (hyprland-zen--truthy-p (hyprland-zen--field tab 'pinned)))
       (cons 'active (hyprland-zen--truthy-p (hyprland-zen--field tab 'active)))
       (cons 'last_seen (hyprland-zen--field tab 'last_seen))))))

(defun hyprland-zen--tab-key (tab)
  "Return stable key for TAB alist."
  (when-let* ((normalized (hyprland-zen--normalize-tab tab)))
    (format "%s/%s/%s"
            (hyprland-zen--field normalized 'browser)
            (hyprland-zen--field normalized 'profile)
            (hyprland-zen--field normalized 'tab_id))))

(defun hyprland-zen--clear-store ()
  "Clear in-memory Zen stores."
  (clrhash hyprland-zen--tabs)
  (clrhash hyprland-zen--workspaces)
  (clrhash hyprland-zen--browser-window->hyprland-address))

(defun hyprland-zen--store-workspace (workspace)
  "Store WORKSPACE in memory after normalization."
  (when-let* ((normalized (hyprland-zen--normalize-workspace workspace))
              (key (hyprland-zen--workspace-key normalized)))
    (puthash key normalized hyprland-zen--workspaces)
    normalized))

(defun hyprland-zen--ensure-workspace-from-tab (tab)
  "Insert workspace inferred from TAB when missing in store."
  (when-let* ((workspace
               (hyprland-zen--normalize-workspace
                `((browser . ,(hyprland-zen--field tab 'browser))
                  (profile . ,(hyprland-zen--field tab 'profile))
                  (workspace_id . ,(hyprland-zen--field tab 'workspace_id))
                  (name . ,(hyprland-zen--field tab 'workspace_name)))) )
              (key (hyprland-zen--workspace-key workspace)))
    (unless (gethash key hyprland-zen--workspaces)
      (puthash key workspace hyprland-zen--workspaces))
    workspace))

(defun hyprland-zen--store-tab (tab)
  "Store TAB in memory after normalization."
  (when-let* ((normalized (hyprland-zen--normalize-tab tab))
              (key (hyprland-zen--tab-key normalized)))
    (puthash key normalized hyprland-zen--tabs)
    (hyprland-zen--ensure-workspace-from-tab normalized)
    normalized))

(defun hyprland-zen--remove-tab-by-key (key)
  "Remove tab KEY from the in-memory store."
  (when (and (stringp key) (not (string-empty-p key)))
    (remhash key hyprland-zen--tabs)))

(defun hyprland-zen-tab-get (key)
  "Return tab object for KEY, or nil."
  (gethash key hyprland-zen--tabs))

(defun hyprland-zen-workspace-get (key)
  "Return workspace object for KEY, or nil."
  (gethash key hyprland-zen--workspaces))

(defun hyprland-zen-workspaces ()
  "Return current Zen workspace list.

Active workspaces are sorted first, then by name."
  (let (out)
    (maphash (lambda (_key workspace) (push workspace out)) hyprland-zen--workspaces)
    (sort out
          (lambda (a b)
            (let ((a-active (hyprland-zen--truthy-p (hyprland-zen--field a 'active)))
                  (b-active (hyprland-zen--truthy-p (hyprland-zen--field b 'active))))
              (if (eq a-active b-active)
                  (string-lessp (hyprland-zen--string (hyprland-zen--field a 'name))
                                (hyprland-zen--string (hyprland-zen--field b 'name)))
                a-active))))))

(defun hyprland-zen-tabs ()
  "Return current Zen tab list.

Active tabs are sorted first, then by title."
  (let (out)
    (maphash (lambda (_key tab) (push tab out)) hyprland-zen--tabs)
    (sort out
          (lambda (a b)
            (let ((a-active (hyprland-zen--truthy-p (hyprland-zen--field a 'active)))
                  (b-active (hyprland-zen--truthy-p (hyprland-zen--field b 'active))))
              (if (eq a-active b-active)
                  (string-lessp (hyprland-zen--string (hyprland-zen--field a 'title))
                                (hyprland-zen--string (hyprland-zen--field b 'title)))
                a-active))))))

(defun hyprland-zen--tab-label (tab)
  "Build completion label from TAB alist."
  (let ((active (if (hyprland-zen--truthy-p (hyprland-zen--field tab 'active)) "*" " "))
        (pinned (if (hyprland-zen--truthy-p (hyprland-zen--field tab 'pinned)) "!" " "))
        (profile (hyprland-zen--string (hyprland-zen--field tab 'profile) "default"))
        (workspace (hyprland-zen--string (hyprland-zen--field tab 'workspace_name) "default"))
        (window-id (hyprland-zen--string (hyprland-zen--field tab 'window_id) "?"))
        (title (hyprland-zen--string (hyprland-zen--field tab 'title) "<untitled tab>"))
        (key (hyprland-zen--tab-key tab)))
    (format "%s%s[%s/%s W%s] %s <%s>" active pinned profile workspace window-id title key)))

(defun hyprland-zen--workspace-label (workspace)
  "Build completion label from WORKSPACE alist."
  (let ((active (if (hyprland-zen--truthy-p (hyprland-zen--field workspace 'active)) "*" " "))
        (profile (hyprland-zen--string (hyprland-zen--field workspace 'profile) "default"))
        (name (hyprland-zen--string (hyprland-zen--field workspace 'name) "default"))
        (key (hyprland-zen--workspace-key workspace)))
    (format "%s[%s] %s <%s>" active profile name key)))

(defun hyprland-zen--message-type (message)
  "Return normalized type string from MESSAGE alist."
  (downcase
   (hyprland-zen--string
    (or (hyprland-zen--field message 'type)
        (hyprland-zen--field message 'event)))))

(defun hyprland-zen--remove-message-key (message)
  "Extract tab key from MESSAGE remove payload."
  (or (hyprland-zen--field message 'key)
      (when-let* ((tab (hyprland-zen--field message 'tab)))
        (hyprland-zen--tab-key tab))
      (hyprland-zen--tab-key message)))

(defun hyprland-zen--remove-workspace-key (message)
  "Extract workspace key from MESSAGE remove payload."
  (or (hyprland-zen--field message 'key)
      (when-let* ((workspace (hyprland-zen--field message 'workspace)))
        (hyprland-zen--workspace-key workspace))
      (hyprland-zen--workspace-key message)))

(defun hyprland-zen--apply-message (message)
  "Apply parsed host MESSAGE to in-memory state."
  (pcase (hyprland-zen--message-type message)
    ("snapshot"
     (hyprland-zen--clear-store)
     (dolist (workspace (or (hyprland-zen--field message 'workspaces) nil))
       (hyprland-zen--store-workspace workspace))
     (dolist (tab (or (hyprland-zen--field message 'tabs) nil))
       (hyprland-zen--store-tab tab))
     (run-hooks 'hyprland-zen-after-refresh-hook)
     t)
    ((or "workspace-snapshot" "workspace_snapshot")
     (clrhash hyprland-zen--workspaces)
     (dolist (workspace (or (hyprland-zen--field message 'workspaces) nil))
       (hyprland-zen--store-workspace workspace))
     (run-hooks 'hyprland-zen-after-refresh-hook)
     t)
    ("upsert"
     (when-let* ((tab (or (hyprland-zen--field message 'tab)
                          message))
                 (stored (hyprland-zen--store-tab tab)))
       (when (hyprland-zen--truthy-p (hyprland-zen--field stored 'active))
         (when-let* ((window-id (hyprland-zen--window-id stored)))
           (hyprland-zen--schedule-window-address-refresh window-id)))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t))
    ((or "workspace-upsert" "workspace_upsert")
     (when-let* ((workspace (or (hyprland-zen--field message 'workspace)
                                message)))
       (hyprland-zen--store-workspace workspace)
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t))
    ("remove"
     (when-let* ((key (hyprland-zen--remove-message-key message)))
       (hyprland-zen--remove-tab-by-key key)
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t))
    ((or "workspace-remove" "workspace_remove")
     (when-let* ((key (hyprland-zen--remove-workspace-key message)))
       (remhash key hyprland-zen--workspaces)
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t))
    ("preview"
     (let ((tab-id (hyprland-zen--string (hyprland-zen--field message 'tab_id))))
       (when (and hyprland-zen--preview-tab-id
                  (string= tab-id hyprland-zen--preview-tab-id))
         (hyprland-zen--display-preview-data-url
          (hyprland-zen--string (hyprland-zen--field message 'image_data_url)))
         t)))
    ("error"
     (when (and hyprland-zen--preview-tab-id
                (string= (hyprland-zen--string (hyprland-zen--field message 'op)) "capture-tab"))
       (hyprland-zen--display-preview-message
        (hyprland-zen--string (hyprland-zen--field message 'message) "Tab preview unavailable")))
     (hyprland--debug "zen host error: %s"
                      (hyprland-zen--string (hyprland-zen--field message 'message) "unknown"))
     nil)
    (_
     (hyprland--debug "zen host unknown payload: %S" message)
     nil)))

(defun hyprland-zen--parse-json (line)
  "Parse JSON LINE into Lisp object, returning nil on failure."
  (condition-case err
      (let ((json-array-type 'list)
            (json-object-type 'alist)
            (json-false :false)
            (json-null nil))
        (json-read-from-string line))
    (error
     (hyprland--debug "zen invalid json line: %s (%s)" line (error-message-string err))
     nil)))

(defun hyprland-zen--handle-line (line)
  "Handle one decoded protocol LINE from host process."
  (when-let* ((payload (hyprland-zen--parse-json line)))
    (hyprland-zen--apply-message payload)))

(defun hyprland-zen--process-filter (_proc chunk)
  "Accumulate CHUNK and dispatch complete JSON lines."
  (setq hyprland-zen--fragment (concat hyprland-zen--fragment chunk))
  (let ((start 0)
        line)
    (while (string-match "\n" hyprland-zen--fragment start)
      (setq line (substring hyprland-zen--fragment start (match-beginning 0)))
      (setq start (match-end 0))
      (unless (string-empty-p line)
        (hyprland-zen--handle-line line)))
    (setq hyprland-zen--fragment
          (substring hyprland-zen--fragment start))))

(defun hyprland-zen--process-sentinel (proc event)
  "Handle Zen host PROC lifecycle EVENT."
  (hyprland--debug "zen host sentinel: %s" (string-trim event))
  (unless (process-live-p proc)
    (setq hyprland-zen--process nil
          hyprland-zen--fragment "")))

(defun hyprland-zen-running-p ()
  "Return non-nil when Zen host process is running."
  (process-live-p hyprland-zen--process))

(defun hyprland-zen--send (payload)
  "Send JSON PAYLOAD to running host process."
  (unless (hyprland-zen-running-p)
    (user-error "hyprland-zen host is not running"))
  (process-send-string hyprland-zen--process
                       (concat (json-encode payload) "\n")))

(defun hyprland-zen-start ()
  "Start Zen native host process."
  (interactive)
  (if (hyprland-zen-running-p)
      hyprland-zen--process
    (unless (and (listp hyprland-zen-host-command)
                 (car hyprland-zen-host-command))
      (user-error "`hyprland-zen-host-command' must be a non-empty command list"))
    (let ((resolved (hyprland-zen--resolve-host-command)))
      (unless resolved
        (user-error "Unable to resolve `%s'; install browser/native-host/hyprland-zen-native-host or set `hyprland-zen-host-command'"
                    (car hyprland-zen-host-command)))
      (setq hyprland-zen--fragment "")
      (setq hyprland-zen--process
            (make-process
             :name "hyprland-zen-bridge"
             :command resolved
             :buffer nil
             :noquery t
             :connection-type 'pipe
             :coding 'utf-8-unix
             :filter #'hyprland-zen--process-filter
             :sentinel #'hyprland-zen--process-sentinel))
      (when hyprland-zen-auto-refresh-on-start
        (hyprland-zen-refresh)
        (hyprland-zen-refresh-workspaces))
      hyprland-zen--process)))

(defun hyprland-zen-stop ()
  "Stop Zen native host process."
  (interactive)
  (when (process-live-p hyprland-zen--process)
    (delete-process hyprland-zen--process))
  (setq hyprland-zen--preview-tab-id nil)
  (hyprland-consult--cleanup-preview)
  (setq hyprland-zen--process nil
        hyprland-zen--fragment ""))

(defun hyprland-zen-refresh ()
  "Request full tab snapshot from Zen host."
  (interactive)
  (hyprland-zen--send '((op . "list-tabs"))))

(defun hyprland-zen-refresh-workspaces ()
  "Request full workspace snapshot from Zen host."
  (interactive)
  (hyprland-zen--send '((op . "list-workspaces"))))

(defun hyprland-zen-open-url (url)
  "Ask Zen host to open URL."
  (interactive "sOpen URL in Zen: ")
  (hyprland-zen--send `((op . "open-url")
                        (url . ,url))))

(defun hyprland-zen--read-tab (prompt)
  "Read tab from completion list using PROMPT."
  (let* ((tabs (hyprland-zen--ensure-tabs-ready))
         (cands (mapcar (lambda (tab)
                          (cons (hyprland-zen--tab-label tab) tab))
                        tabs)))
    (unless cands
      (user-error "No Zen tabs available (bridge disconnected or extension not ready)"))
    (if (and (fboundp 'consult--read)
             (fboundp 'consult--lookup-cdr))
        (consult--read cands
                       :prompt prompt
                       :require-match t
                       :sort nil
                       :lookup #'consult--lookup-cdr
                       :preview-key hyprland-zen-preview-key
                       :state #'hyprland-zen--preview-state)
      (cdr (assoc (completing-read prompt cands nil t) cands)))))

(defun hyprland-zen--read-workspace (prompt)
  "Read workspace from completion list using PROMPT."
  (let* ((workspaces (hyprland-zen--ensure-workspaces-ready))
         (cands (mapcar (lambda (workspace)
                          (cons (hyprland-zen--workspace-label workspace) workspace))
                        workspaces)))
    (unless cands
      (user-error "No Zen workspaces available (bridge disconnected or extension not ready)"))
    (cdr (assoc (completing-read prompt cands nil t) cands))))

(defun hyprland-zen-tab-switch (&optional tab)
  "Activate TAB via host command.

When TAB is nil, prompt from current registry."
  (interactive)
  (let* ((target (or tab (hyprland-zen--read-tab "Zen tab: ")))
         (key (hyprland-zen--tab-key target))
         (window-id (hyprland-zen--window-id target))
         (tab-id (hyprland-zen--string (hyprland-zen--field target 'tab_id)))
         (workspace-id (hyprland-zen--string (hyprland-zen--field target 'workspace_id)))
         (sync-group (hyprland-zen--string (hyprland-zen--field target 'sync_group))))
    (when window-id
      (hyprland-zen--jump-to-known-window window-id))
    (hyprland-zen--send `((op . "activate-tab")
                          (key . ,key)
                          (tab_id . ,tab-id)
                          (window_id . ,window-id)
                          (workspace_id . ,workspace-id)
                          (sync_group . ,sync-group)))
    (when window-id
      (hyprland-zen--schedule-window-address-refresh window-id))
    key))

(defun hyprland-zen-tab-close (&optional tab)
  "Close TAB via host command.

When TAB is nil, prompt from current registry."
  (interactive)
  (let* ((target (or tab (hyprland-zen--read-tab "Close Zen tab: ")))
         (key (hyprland-zen--tab-key target)))
    (hyprland-zen--send `((op . "close-tab")
                          (key . ,key)))
    key))

(defun hyprland-zen-workspace-switch (&optional workspace)
  "Activate WORKSPACE via host command.

When WORKSPACE is nil, prompt from current registry."
  (interactive)
  (let* ((target (or workspace (hyprland-zen--read-workspace "Zen workspace: ")))
         (key (hyprland-zen--workspace-key target)))
    (hyprland-zen--send `((op . "activate-workspace")
                          (key . ,key)))
    key))

(define-minor-mode hyprland-zen-mode
  "Keep Zen bridge host process active."
  :global t
  :group 'hyprland-zen
  (if hyprland-zen-mode
      (hyprland-zen-start)
    (hyprland-zen-stop)))

(provide 'hyprland-zen)
;;; hyprland-zen.el ends here
