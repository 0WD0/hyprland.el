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

(defcustom hyprland-zen-bootstrap-retry-seconds 8
  "Seconds to keep retrying initial tab/workspace refresh after bridge start."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-bootstrap-retry-interval 1.0
  "Seconds between bootstrap refresh retries while bridge is warming up."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-trace-max-entries 240
  "Maximum number of in-memory bridge trace entries to retain.

Each trace entry records inbound/outbound protocol payloads for runtime
diagnosis in real environments."
  :type 'integer
  :group 'hyprland-zen)

(defcustom hyprland-zen-error-notify-throttle-seconds 2.0
  "Minimum seconds between identical runtime error echo messages."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-native-host-auto-restart t
  "When non-nil, auto-restart stale native adapter on repeated bridge disconnects."
  :type 'boolean
  :group 'hyprland-zen)

(defcustom hyprland-zen-native-host-restart-threshold 8
  "Consecutive bridge-not-connected errors before restarting native adapter."
  :type 'integer
  :group 'hyprland-zen)

(defcustom hyprland-zen-native-host-restart-cooldown 20.0
  "Minimum seconds between automatic native adapter restart attempts."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-native-host-pkill-pattern
  "hyprland-zen-native-host .*hyprland-zen-bridge@0wd0"
  "Pattern passed to `pkill -f' for stale browser-launched native adapters."
  :type 'string
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
(defvar hyprland-zen--preview-candidates nil)
(defvar hyprland-zen--retry-refresh-timer nil)
(defvar hyprland-zen--bootstrap-timer nil)
(defvar hyprland-zen--bootstrap-deadline nil)

(defvar hyprland-zen--trace nil
  "Recent bridge protocol entries (newest first).")

(defvar hyprland-zen--last-error-notify-signature nil)
(defvar hyprland-zen--last-error-notify-at nil)
(defvar hyprland-zen--bridge-not-connected-streak 0)
(defvar hyprland-zen--last-native-host-restart-at nil)

(defvar hyprland-zen--started-at nil)
(defvar hyprland-zen--last-line-at nil)
(defvar hyprland-zen--last-line-type nil)
(defvar hyprland-zen--last-snapshot-at nil)
(defvar hyprland-zen--last-workspace-snapshot-at nil)
(defvar hyprland-zen--last-preview-request-at nil)
(defvar hyprland-zen--last-preview-response-at nil)
(defvar hyprland-zen--last-error-message nil)
(defvar hyprland-zen--last-error-op nil)
(defvar hyprland-zen--last-sentinel-event nil)
(defvar hyprland-zen--bridge-connected nil)
(defvar hyprland-zen--bridge-last-reason nil)
(defvar hyprland-zen--queued-op-count 0)
(defvar hyprland-zen--last-queued-op nil)
(defvar hyprland-zen--messages-in 0)
(defvar hyprland-zen--messages-out 0)

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
       (let* ((tab (cond
                    ((and (listp cand) (hyprland-zen--field cand 'tab_id))
                     cand)
                    ((and (stringp cand)
                          (fboundp 'consult--lookup-cdr)
                          hyprland-zen--preview-candidates)
                     (consult--lookup-cdr cand hyprland-zen--preview-candidates nil))
                    ((and (stringp cand) hyprland-zen--preview-candidates)
                     (cdr (assoc cand hyprland-zen--preview-candidates)))
                    (t nil)))
              (tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id))))
         (if (string-empty-p tab-id)
             (hyprland-zen--display-preview-message "Candidate missing tab metadata")
           (setq hyprland-zen--preview-tab-id tab-id)
           (hyprland-zen--display-preview-message "Loading tab preview...")
           (if (or hyprland-zen--bridge-connected
                   (not (and (stringp hyprland-zen--last-error-message)
                             (string-match-p "browser-bridge-" hyprland-zen--last-error-message))))
               (condition-case err
                   (hyprland-zen--send `((op . "capture-tab")
                                         (tab_id . ,tab-id)))
                 (error
                  (hyprland-zen--display-preview-message
                   (format "Preview request failed: %s" (error-message-string err)))))
             (hyprland-zen--display-preview-message "Bridge reconnecting; preview deferred"))))))
    ((or 'exit 'return)
     (setq hyprland-zen--preview-tab-id nil)
     (setq hyprland-zen--preview-candidates nil)
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

(defun hyprland-zen--now ()
  "Return current timestamp as float seconds."
  (float-time))

(defun hyprland-zen--seconds-since (timestamp)
  "Return elapsed seconds since TIMESTAMP, or nil."
  (when timestamp
    (max 0.0 (- (hyprland-zen--now) timestamp))))

(defun hyprland-zen--touch-line (type)
  "Record that host emitted message TYPE now."
  (setq hyprland-zen--last-line-at (hyprland-zen--now)
        hyprland-zen--last-line-type type)
  (cl-incf hyprland-zen--messages-in))

(defun hyprland-zen--record-error (message &optional op)
  "Record latest host MESSAGE and OP for diagnostics."
  (setq hyprland-zen--last-error-message (hyprland-zen--string message)
        hyprland-zen--last-error-op (hyprland-zen--string op)))

(defun hyprland-zen--clear-bridge-disconnect-error ()
  "Clear stale disconnect diagnostics when bridge has recovered."
  (when (and (stringp hyprland-zen--last-error-message)
             (or (string-match-p "browser-bridge-not-connected" hyprland-zen--last-error-message)
                 (string-match-p "browser-bridge-disconnected" hyprland-zen--last-error-message)))
    (setq hyprland-zen--last-error-message nil
          hyprland-zen--last-error-op nil)))

(defun hyprland-zen--maybe-restart-native-host (reason)
  "Restart stale native adapter process when REASON repeats too often."
  (when (and hyprland-zen-native-host-auto-restart
             (>= hyprland-zen--bridge-not-connected-streak
                 (max 1 hyprland-zen-native-host-restart-threshold))
             (executable-find "pkill")
             (> (length (string-trim hyprland-zen-native-host-pkill-pattern)) 0)
             (let ((last (or hyprland-zen--last-native-host-restart-at 0.0)))
               (>= (- (hyprland-zen--now) last)
                   (max 0.0 hyprland-zen-native-host-restart-cooldown))))
    (let ((exit-code (call-process "pkill" nil nil nil "-f" hyprland-zen-native-host-pkill-pattern)))
      (setq hyprland-zen--last-native-host-restart-at (hyprland-zen--now)
            hyprland-zen--bridge-not-connected-streak 0)
      (hyprland-zen--trace-add
       'native-restart
       `((reason . ,reason)
         (pkill-pattern . ,hyprland-zen-native-host-pkill-pattern)
         (exit-code . ,(or exit-code -1))))
      (hyprland--debug "zen native adapter restart requested (%s), pkill exit=%s"
                       reason (or exit-code -1)))))

(defun hyprland-zen--reset-runtime-metrics ()
  "Reset runtime counters and timestamps for diagnostics."
  (setq hyprland-zen--started-at nil
        hyprland-zen--last-line-at nil
        hyprland-zen--last-line-type nil
        hyprland-zen--last-snapshot-at nil
        hyprland-zen--last-workspace-snapshot-at nil
        hyprland-zen--last-preview-request-at nil
        hyprland-zen--last-preview-response-at nil
        hyprland-zen--last-error-message nil
        hyprland-zen--last-error-op nil
        hyprland-zen--last-error-notify-signature nil
        hyprland-zen--last-error-notify-at nil
        hyprland-zen--bridge-not-connected-streak 0
        hyprland-zen--last-native-host-restart-at nil
        hyprland-zen--last-sentinel-event nil
        hyprland-zen--bridge-connected nil
        hyprland-zen--bridge-last-reason nil
        hyprland-zen--queued-op-count 0
        hyprland-zen--last-queued-op nil
        hyprland-zen--messages-in 0
        hyprland-zen--messages-out 0)
  (setq hyprland-zen--trace nil))

(defun hyprland-zen--trace-add (dir payload)
  "Record one bridge trace entry for DIR and PAYLOAD."
  (when (> hyprland-zen-trace-max-entries 0)
    (push (list :ts (hyprland-zen--now)
                :dir dir
                :payload payload)
          hyprland-zen--trace)
    (when (> (length hyprland-zen--trace) hyprland-zen-trace-max-entries)
      (setcdr (nthcdr (1- hyprland-zen-trace-max-entries) hyprland-zen--trace) nil))))

(defun hyprland-zen--cancel-bootstrap-retry ()
  "Cancel ongoing bootstrap retry timer state."
  (when (timerp hyprland-zen--bootstrap-timer)
    (cancel-timer hyprland-zen--bootstrap-timer))
  (setq hyprland-zen--bootstrap-timer nil
        hyprland-zen--bootstrap-deadline nil))

(defun hyprland-zen--bootstrap-ready-p ()
  "Return non-nil when both tab and workspace stores are populated."
  (and (hyprland-zen-tabs)
       (hyprland-zen-workspaces)))

(defun hyprland-zen--bootstrap-active-p ()
  "Return non-nil when bootstrap retry window is currently active."
  (and hyprland-zen--bootstrap-deadline
       (> hyprland-zen--bootstrap-deadline (hyprland-zen--now))))

(defun hyprland-zen--notify-error (op err-message)
  "Echo runtime error for OP and ERR-MESSAGE with throttling."
  (let* ((signature (format "%s|%s" op err-message))
         (now (hyprland-zen--now))
         (should-echo
          (or (not (equal signature hyprland-zen--last-error-notify-signature))
              (not hyprland-zen--last-error-notify-at)
              (>= (- now hyprland-zen--last-error-notify-at)
                  (max 0.0 hyprland-zen-error-notify-throttle-seconds)))))
    (when should-echo
      (setq hyprland-zen--last-error-notify-signature signature
            hyprland-zen--last-error-notify-at now)
      (message "hyprland-zen error (%s): %s" op err-message))))

(defun hyprland-zen--bootstrap-retry-tick ()
  "Retry tab/workspace refresh during startup warmup window."
  (setq hyprland-zen--bootstrap-timer nil)
  (unless (hyprland-zen-running-p)
    (hyprland-zen--cancel-bootstrap-retry))
  (when (and (hyprland-zen-running-p)
             hyprland-zen--bootstrap-deadline
             (< (hyprland-zen--now) hyprland-zen--bootstrap-deadline)
             (not (hyprland-zen--bootstrap-ready-p)))
    (ignore-errors
      (hyprland-zen-refresh)
      (hyprland-zen-refresh-workspaces))
    (setq hyprland-zen--bootstrap-timer
          (run-at-time
           (max 0.2 hyprland-zen-bootstrap-retry-interval)
           nil
           #'hyprland-zen--bootstrap-retry-tick)))
  (when (hyprland-zen--bootstrap-ready-p)
    (hyprland-zen--cancel-bootstrap-retry)))

(defun hyprland-zen--start-bootstrap-retry ()
  "Start bounded startup retries for initial bridge synchronization."
  (hyprland-zen--cancel-bootstrap-retry)
  (setq hyprland-zen--bootstrap-deadline
        (+ (hyprland-zen--now) (max 0.0 hyprland-zen-bootstrap-retry-seconds)))
  (hyprland-zen--bootstrap-retry-tick))

(defun hyprland-zen--schedule-retry-refresh ()
  "Schedule a short delayed refresh after bridge-not-connected errors."
  (when (timerp hyprland-zen--retry-refresh-timer)
    (cancel-timer hyprland-zen--retry-refresh-timer))
  (setq hyprland-zen--retry-refresh-timer
        (run-at-time
         0.8 nil
         (lambda ()
           (setq hyprland-zen--retry-refresh-timer nil)
           (when (hyprland-zen-running-p)
             (ignore-errors
               (hyprland-zen-refresh)
               (hyprland-zen-refresh-workspaces)))))))

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
  (let ((type (hyprland-zen--message-type message)))
    (hyprland-zen--touch-line type)
    (hyprland-zen--trace-add 'in message)
    (unless (string= type "error")
      (setq hyprland-zen--bridge-not-connected-streak 0))
    (pcase type
      ("snapshot"
       (setq hyprland-zen--last-snapshot-at hyprland-zen--last-line-at)
       (setq hyprland-zen--bridge-connected t
             hyprland-zen--queued-op-count 0)
       (hyprland-zen--clear-bridge-disconnect-error)
       (hyprland-zen--clear-store)
       (dolist (workspace (or (hyprland-zen--field message 'workspaces) nil))
         (hyprland-zen--store-workspace workspace))
       (dolist (tab (or (hyprland-zen--field message 'tabs) nil))
         (hyprland-zen--store-tab tab))
       (when (hyprland-zen--bootstrap-ready-p)
         (hyprland-zen--cancel-bootstrap-retry))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t)
      ((or "workspace-snapshot" "workspace_snapshot")
       (setq hyprland-zen--last-workspace-snapshot-at hyprland-zen--last-line-at)
       (setq hyprland-zen--bridge-connected t)
       (hyprland-zen--clear-bridge-disconnect-error)
       (clrhash hyprland-zen--workspaces)
       (dolist (workspace (or (hyprland-zen--field message 'workspaces) nil))
         (hyprland-zen--store-workspace workspace))
       (when (hyprland-zen--bootstrap-ready-p)
         (hyprland-zen--cancel-bootstrap-retry))
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
      ((or "bridge-state" "bridge_state")
       (setq hyprland-zen--bridge-connected
             (hyprland-zen--truthy-p (hyprland-zen--field message 'connected))
             hyprland-zen--bridge-last-reason
             (hyprland-zen--string (hyprland-zen--field message 'reason)))
       (when hyprland-zen--bridge-connected
         (setq hyprland-zen--queued-op-count 0
               hyprland-zen--bridge-not-connected-streak 0)
         (hyprland-zen--clear-bridge-disconnect-error))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t)
      ("queued"
       (setq hyprland-zen--bridge-connected nil
             hyprland-zen--last-queued-op
             (hyprland-zen--string (hyprland-zen--field message 'op))
             hyprland-zen--queued-op-count
             (or (and (numberp (hyprland-zen--field message 'queue_length))
                      (hyprland-zen--field message 'queue_length))
                 (1+ hyprland-zen--queued-op-count)))
       (when-let* ((reason (hyprland-zen--string (hyprland-zen--field message 'message))))
         (hyprland-zen--record-error reason (hyprland-zen--field message 'op)))
       (unless (hyprland-zen--bootstrap-active-p)
         (hyprland-zen--start-bootstrap-retry))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       nil)
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
         (setq hyprland-zen--last-preview-response-at hyprland-zen--last-line-at)
         (when (and hyprland-zen--preview-tab-id
                    (string= tab-id hyprland-zen--preview-tab-id))
           (hyprland-zen--display-preview-data-url
            (hyprland-zen--string (hyprland-zen--field message 'image_data_url)))
           t)))
      ("error"
       (hyprland-zen--record-error
        (hyprland-zen--field message 'message)
        (hyprland-zen--field message 'op))
       (when-let* ((reason (hyprland-zen--string (hyprland-zen--field message 'message)))
                   (op-name (hyprland-zen--string (hyprland-zen--field message 'op))))
         (when (or (string-match-p "browser-bridge-not-connected" reason)
                   (string-match-p "browser-bridge-disconnected" reason))
           (setq hyprland-zen--bridge-connected nil)
           (when (member op-name '("list-tabs" "list-workspaces"))
             (hyprland-zen--schedule-retry-refresh))
           (if (member op-name '("open-url" "capture-tab" "activate-tab" "activate-workspace"))
               (setq hyprland-zen--bridge-not-connected-streak
                     (max hyprland-zen--bridge-not-connected-streak
                          (max 1 hyprland-zen-native-host-restart-threshold)))
             (cl-incf hyprland-zen--bridge-not-connected-streak))
           (unless (hyprland-zen--bootstrap-active-p)
             (hyprland-zen--start-bootstrap-retry))
           (hyprland-zen--maybe-restart-native-host reason)))
       (when-let* ((op (hyprland-zen--string (hyprland-zen--field message 'op)))
                   (err-message (hyprland-zen--string (hyprland-zen--field message 'message))))
         (when (member op '("activate-tab" "activate-workspace" "list-tabs" "list-workspaces"))
           (hyprland-zen--notify-error op err-message)))
       (when (and hyprland-zen--preview-tab-id
                  (string= (hyprland-zen--string (hyprland-zen--field message 'op)) "capture-tab"))
         (hyprland-zen--display-preview-message
          (hyprland-zen--string (hyprland-zen--field message 'message) "Tab preview unavailable")))
       (hyprland--debug "zen host error: %s"
                        (hyprland-zen--string (hyprland-zen--field message 'message) "unknown"))
       nil)
      (_
       (hyprland--debug "zen host unknown payload: %S" message)
       nil))))

(defun hyprland-zen--parse-json (line)
  "Parse JSON LINE into Lisp object, returning nil on failure."
  (condition-case err
      (let ((json-array-type 'list)
            (json-object-type 'alist)
            (json-false :false)
            (json-null nil))
        (json-read-from-string line))
    (error
     (hyprland-zen--trace-add 'parse-error line)
     (hyprland--debug "zen invalid json line: %s (%s)" line (error-message-string err))
     nil)))

(defun hyprland-zen--handle-line (line)
  "Handle one decoded protocol LINE from host process."
  (when-let* ((payload (hyprland-zen--parse-json line)))
    (hyprland-zen--apply-message payload)))

(defun hyprland-zen--process-filter (_proc chunk)
  "Accumulate CHUNK and dispatch complete JSON lines."
  ;; Use a local snapshot buffer so callbacks cannot corrupt indexing by
  ;; mutating `hyprland-zen--fragment' (e.g. stop/restart in hooks/errors).
  (let ((stream (concat hyprland-zen--fragment chunk))
        (start 0)
        line)
    (while (string-match "\n" stream start)
      (setq line (substring stream start (match-beginning 0)))
      (setq start (match-end 0))
      (unless (string-empty-p line)
        (hyprland-zen--handle-line line)))
    (setq hyprland-zen--fragment
          (if (< start (length stream))
              (substring stream start)
            ""))))

(defun hyprland-zen--process-sentinel (proc event)
  "Handle Zen host PROC lifecycle EVENT."
  (hyprland--debug "zen host sentinel: %s" (string-trim event))
  (hyprland-zen--trace-add 'sentinel (string-trim event))
  (setq hyprland-zen--last-sentinel-event (string-trim event))
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
  (hyprland-zen--trace-add 'out payload)
  (cl-incf hyprland-zen--messages-out)
  (when (equal (hyprland-zen--field payload 'op) "capture-tab")
    (setq hyprland-zen--last-preview-request-at (hyprland-zen--now)))
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
      (hyprland-zen--reset-runtime-metrics)
      (setq hyprland-zen--started-at (hyprland-zen--now))
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
      (hyprland-zen--start-bootstrap-retry)
      hyprland-zen--process)))

(defun hyprland-zen-stop ()
  "Stop Zen native host process."
  (interactive)
  (when (process-live-p hyprland-zen--process)
    (delete-process hyprland-zen--process))
  (when (timerp hyprland-zen--retry-refresh-timer)
    (cancel-timer hyprland-zen--retry-refresh-timer))
  (hyprland-zen--cancel-bootstrap-retry)
  (setq hyprland-zen--preview-tab-id nil)
  (setq hyprland-zen--preview-candidates nil)
  (hyprland-consult--cleanup-preview)
  (setq hyprland-zen--process nil
        hyprland-zen--fragment ""
        hyprland-zen--retry-refresh-timer nil))

(defun hyprland-zen-status ()
  "Return and optionally print current Zen bridge diagnostics.

When called interactively, print a short status line in echo area."
  (interactive)
  (let* ((running (hyprland-zen-running-p))
         (tab-count (hash-table-count hyprland-zen--tabs))
         (workspace-count (hash-table-count hyprland-zen--workspaces))
         (report
          (list :running running
                :pid (when running (process-id hyprland-zen--process))
                :tab-count tab-count
                :workspace-count workspace-count
                :messages-in hyprland-zen--messages-in
                :messages-out hyprland-zen--messages-out
                :trace-count (length hyprland-zen--trace)
                :started-seconds-ago (hyprland-zen--seconds-since hyprland-zen--started-at)
                :last-message-type hyprland-zen--last-line-type
                :last-message-seconds-ago (hyprland-zen--seconds-since hyprland-zen--last-line-at)
                :last-snapshot-seconds-ago (hyprland-zen--seconds-since hyprland-zen--last-snapshot-at)
                :last-workspace-snapshot-seconds-ago
                (hyprland-zen--seconds-since hyprland-zen--last-workspace-snapshot-at)
                :last-preview-request-seconds-ago
                (hyprland-zen--seconds-since hyprland-zen--last-preview-request-at)
                :last-preview-response-seconds-ago
                (hyprland-zen--seconds-since hyprland-zen--last-preview-response-at)
                :bridge-connected hyprland-zen--bridge-connected
                :bridge-last-reason hyprland-zen--bridge-last-reason
                :queued-op-count hyprland-zen--queued-op-count
                :last-queued-op hyprland-zen--last-queued-op
                :bootstrap-retry-seconds-left
                (when hyprland-zen--bootstrap-deadline
                  (max 0.0 (- hyprland-zen--bootstrap-deadline (hyprland-zen--now))))
                :last-error-op hyprland-zen--last-error-op
                :last-error-message hyprland-zen--last-error-message
                :last-sentinel-event hyprland-zen--last-sentinel-event)))
    (when (called-interactively-p 'interactive)
      (message
       "Zen bridge: running=%s tabs=%d workspaces=%d in/out=%d/%d trace=%d last=%s %.1fs ago err=%s"
       (if running "yes" "no")
       tab-count
       workspace-count
       hyprland-zen--messages-in
       hyprland-zen--messages-out
       (length hyprland-zen--trace)
       (or hyprland-zen--last-line-type "none")
       (or (hyprland-zen--seconds-since hyprland-zen--last-line-at) -1.0)
       (or hyprland-zen--last-error-message "none")))
    report))

(defun hyprland-zen-trace-reset ()
  "Clear runtime bridge trace entries."
  (interactive)
  (setq hyprland-zen--trace nil)
  (when (called-interactively-p 'interactive)
    (message "hyprland-zen trace cleared")))

(defun hyprland-zen-trace-report (&optional limit)
  "Render recent bridge trace entries into a report buffer.

LIMIT controls maximum entries (default 80)."
  (interactive "P")
  (let* ((n (max 1 (truncate (or (and (numberp limit) limit)
                                 (and (listp limit) (prefix-numeric-value limit))
                                 80))))
         (entries (cl-subseq hyprland-zen--trace 0 (min n (length hyprland-zen--trace))))
         (buf (get-buffer-create "*hyprland-zen-trace*"))
         (status (hyprland-zen-status)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "hyprland-zen trace report\n\nrunning=%s tabs=%s workspaces=%s in/out=%s/%s trace=%s\nlast-error-op=%s\nlast-error-message=%s\n\n"
                        (plist-get status :running)
                        (plist-get status :tab-count)
                        (plist-get status :workspace-count)
                        (plist-get status :messages-in)
                        (plist-get status :messages-out)
                        (plist-get status :trace-count)
                        (or (plist-get status :last-error-op) "")
                        (or (plist-get status :last-error-message) "")))
        (dolist (entry entries)
          (insert
           (format "[%s] %s %S\n"
                   (format-time-string "%F %T" (seconds-to-time (or (plist-get entry :ts) 0.0)))
                   (plist-get entry :dir)
                   (plist-get entry :payload))))
        (goto-char (point-min))
        (special-mode)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buf))
    buf))

(defun hyprland-zen-doctor (&optional timeout)
  "Run lightweight Zen bridge diagnosis and return report plist.

TIMEOUT controls how long to wait for initial tab/workspace snapshots."
  (interactive "P")
  (let* ((wait-time (cond
                     ((numberp timeout) timeout)
                     ((and timeout (listp timeout)) (prefix-numeric-value timeout))
                     (t hyprland-zen-initial-sync-timeout)))
         (_ (unless (hyprland-zen-running-p)
              (hyprland-zen-start)))
         (_ (progn
              (hyprland-zen-refresh)
              (hyprland-zen-refresh-workspaces)))
         (tabs (hyprland-zen--wait-for-tabs wait-time))
         (spaces (hyprland-zen--ensure-workspaces-ready))
         (status (hyprland-zen-status))
         (report (append (list :wait-time wait-time
                               :tabs-ready (and tabs t)
                               :workspaces-ready (and spaces t))
                         status)))
    (when (called-interactively-p 'interactive)
      (message
       "Zen doctor: running=%s tabs=%d(%s) workspaces=%d(%s) last-error=%s"
       (if (plist-get report :running) "yes" "no")
       (or (plist-get report :tab-count) 0)
       (if (plist-get report :tabs-ready) "ready" "empty")
       (or (plist-get report :workspace-count) 0)
       (if (plist-get report :workspaces-ready) "ready" "empty")
       (or (plist-get report :last-error-message) "none")))
    report))

(defun hyprland-zen-refresh ()
  "Request full tab snapshot from Zen host."
  (interactive)
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start))
  (hyprland-zen--send '((op . "list-tabs"))))

(defun hyprland-zen-refresh-workspaces ()
  "Request full workspace snapshot from Zen host."
  (interactive)
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start))
  (hyprland-zen--send '((op . "list-workspaces"))))

(defun hyprland-zen-open-url (url)
  "Ask Zen host to open URL."
  (interactive "sOpen URL in Zen: ")
  (hyprland-zen--send `((op . "open-url")
                        (url . ,url))))

(defun hyprland-zen--resolve-selection (selected candidates field)
  "Resolve SELECTED value back to candidate object carrying FIELD.

SELECTED may already be an alist object or a completion label string from
different completion frontends/versions. CANDIDATES is the original
`(LABEL . OBJECT)' alist."
  (cond
   ((and (listp selected)
         (hyprland-zen--field selected field))
    selected)
   ((stringp selected)
    (or (when (fboundp 'consult--lookup-cdr)
          (consult--lookup-cdr selected candidates nil))
        (cdr (assoc selected candidates))))
   (t nil)))

(defun hyprland-zen--read-tab (prompt)
  "Read tab from completion list using PROMPT."
  (let* ((tabs (hyprland-zen--ensure-tabs-ready))
         (cands (mapcar (lambda (tab)
                          (cons (hyprland-zen--tab-label tab) tab))
                        tabs)))
    (unless cands
      (user-error
       "No Zen tabs available (bridge disconnected or extension not ready). Check `M-x hyprland-zen-status' / `M-x hyprland-zen-doctor'"))
    (if (and (fboundp 'consult--read)
             (fboundp 'consult--lookup-cdr))
        (let ((hyprland-zen--preview-candidates cands))
          (let* ((selected
                  (consult--read cands
                                 :prompt prompt
                                 :require-match t
                                 :sort nil
                                 :lookup #'consult--lookup-cdr
                                 :preview-key hyprland-zen-preview-key
                                 :state #'hyprland-zen--preview-state))
                 (tab (hyprland-zen--resolve-selection selected cands 'tab_id)))
            (unless tab
              (user-error "Selected Zen tab metadata is unavailable; run `M-x hyprland-zen-refresh'"))
            tab))
      (cdr (assoc (completing-read prompt cands nil t) cands)))))

(defun hyprland-zen--read-workspace (prompt)
  "Read workspace from completion list using PROMPT."
  (let* ((workspaces (hyprland-zen--ensure-workspaces-ready))
         (cands (mapcar (lambda (workspace)
                          (cons (hyprland-zen--workspace-label workspace) workspace))
                        workspaces)))
    (unless cands
      (user-error
       "No Zen workspaces available (bridge disconnected or extension not ready). Check `M-x hyprland-zen-status' / `M-x hyprland-zen-doctor'"))
    (let* ((selected (completing-read prompt cands nil t))
           (workspace (hyprland-zen--resolve-selection selected cands 'workspace_id)))
      (unless workspace
        (user-error "Selected Zen workspace metadata is unavailable; run `M-x hyprland-zen-refresh-workspaces'"))
      workspace)))

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
