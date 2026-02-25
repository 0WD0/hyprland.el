;;; hyprland-zen.el --- Zen browser bridge for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Experimental Zen tab bridge over a line-delimited JSON host process.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'consult)
(require 'hyprland-base)
(require 'hyprland-preview-ui)

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

(defcustom hyprland-zen-recover-startup-socket-conflict t
  "When non-nil, retry startup once after killing stale line-stdio bridge."
  :type 'boolean
  :group 'hyprland-zen)

(defcustom hyprland-zen-line-host-pkill-pattern
  "hyprland-zen-native-host"
  "Pattern passed to `pkill -f' when recovering startup socket conflicts."
  :type 'string
  :group 'hyprland-zen)

(defcustom hyprland-zen-jump-to-window-on-tab-switch t
  "When non-nil, tab switch also focuses corresponding Hyprland window.

Window selection is resolved from title-matching keywords before/after
`activate-tab`, avoiding long-lived window-address caches."
  :type 'boolean
  :group 'hyprland-zen)

(defcustom hyprland-zen-jump-match-by-title t
  "When non-nil, resolve browser window jumps by active tab title first.

This avoids relying only on long-lived browser-window -> Hyprland-address cache,
which can drift in multi-window workflows."
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

(defcustom hyprland-zen-preview-cache-ttl 3
  "Maximum age of cached tab previews in seconds."
  :type 'integer
  :group 'hyprland-zen)

(defcustom hyprland-zen-initial-sync-timeout 1.5
  "Seconds to wait for initial tab snapshot when local store is empty."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-op-retry-timeout 1.5
  "Seconds to wait for bridge recovery before one-shot op resend."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-post-activate-jump-delay 0.22
  "Seconds to wait after `activate-tab` before explicit Hyprland jump.

In multi-window setups, browser focus/title updates may lag command dispatch by
a short moment. Delaying the explicit jump improves window resolution accuracy."
  :type 'number
  :group 'hyprland-zen)

(defcustom hyprland-zen-trace-max-entries 240
  "Maximum number of in-memory bridge trace entries to retain.

Each trace entry records inbound/outbound protocol payloads for runtime
diagnosis in real environments."
  :type 'integer
  :group 'hyprland-zen)

(defvar hyprland-zen--tabs (make-hash-table :test #'equal)
  "Zen tab store keyed by `browser/profile/tab_id'.")

(defvar hyprland-zen--workspaces (make-hash-table :test #'equal)
  "Zen workspace store keyed by `browser/profile/workspace_id'.")

(defvar hyprland-zen--process nil)
(defvar hyprland-zen--fragment "")
(defvar hyprland-zen--preview-tab-id nil)
(defvar hyprland-zen--preview-candidates nil)
(defvar hyprland-zen--preview-cache (make-hash-table :test #'equal))
(defvar hyprland-zen--preview-request-url (make-hash-table :test #'equal))
(defvar hyprland-zen--preview-inflight-tab-id nil)
(defvar hyprland-zen--preview-pending-tab-id nil)
(defvar hyprland-zen--preview-pending-url nil)

(defvar hyprland-zen--trace nil
  "Recent bridge protocol entries (newest first).")

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
(defvar hyprland-zen--queued-event-serial 0)
(defvar hyprland-zen--messages-in 0)
(defvar hyprland-zen--messages-out 0)
(defvar hyprland-zen--last-keyword1-title nil)
(defvar hyprland-zen--last-keyword1-addresses nil)
(defvar hyprland-zen--last-keyword2-title nil)
(defvar hyprland-zen--last-keyword2-addresses nil)
(defvar hyprland-zen--last-jump-address nil)
(defvar hyprland-zen--last-jump-strategy nil)

(defvar hyprland-zen-after-refresh-hook nil
  "Hook run after Zen tab store changes.")

(declare-function hyprland-jump "hyprland-sync" (address))
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
  (let ((out (hyprland-zen--string (hyprland-zen--field tab 'window_id))))
    (unless (string-empty-p out)
      out)))

(defun hyprland-zen--browser-class-p (class)
  "Return non-nil when CLASS looks like configured browser class."
  (let ((c (downcase (hyprland-zen--string class))))
    (or (null hyprland-zen-window-class-regexp)
        (string-match-p hyprland-zen-window-class-regexp c))))

(defun hyprland-zen--active-tab-for-window (window-id)
  "Return active tab object for browser WINDOW-ID from local store."
  (let ((wid (hyprland-zen--string window-id)))
    (unless (string-empty-p wid)
      (cl-find-if (lambda (tab)
                    (let ((tab-window-id (hyprland-zen--window-id tab)))
                      (and (stringp tab-window-id)
                           (string= wid tab-window-id)
                           (hyprland-zen--truthy-p (hyprland-zen--field tab 'active)))))
                  (hyprland-zen-tabs)))))

(defun hyprland-zen--tab-in-window (window-id &optional exclude-tab-id)
  "Return any tab from WINDOW-ID, optionally excluding EXCLUDE-TAB-ID."
  (let ((wid (hyprland-zen--string window-id))
        (exclude (hyprland-zen--string exclude-tab-id)))
    (unless (string-empty-p wid)
      (cl-find-if (lambda (tab)
                    (let ((tab-window-id (hyprland-zen--window-id tab))
                          (tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id))))
                      (and (stringp tab-window-id)
                           (string= wid tab-window-id)
                           (or (string-empty-p exclude)
                               (not (string= tab-id exclude))))))
                  (hyprland-zen-tabs)))))

(defun hyprland-zen--active-hyprland-window-title ()
  "Return active browser-window title from Hyprland, or nil."
  (condition-case _err
      (when-let* ((active (hyprland--hyprctl-json "activewindow"))
                  (_ (hyprland-zen--browser-class-p (hyprland-zen--field active 'class)))
                  (title (hyprland-zen--string (hyprland-zen--field active 'title))))
        (unless (string-empty-p title)
          title))
    (error nil)))

(defun hyprland-zen--title-match-score (window-title tab-title)
  "Return match score between WINDOW-TITLE and TAB-TITLE."
  (let* ((w (downcase (hyprland-zen--string window-title)))
         (tab (downcase (hyprland-zen--string tab-title))))
    (cond
     ((or (string-empty-p w) (string-empty-p tab)) 0)
     ((string= w tab) 100)
     ((string-prefix-p tab w) 80)
     ((and (> (length tab) 5) (string-match-p (regexp-quote tab) w)) 60)
     (t 0))))

(defun hyprland-zen--browser-clients ()
  "Return current Hyprland clients that look like supported browsers."
  (let (out)
    (condition-case _err
        (dolist (client (or (hyprland--hyprctl-json "clients") nil))
          (when (hyprland-zen--browser-class-p (hyprland-zen--field client 'class))
            (push client out)))
      (error nil))
    out))

(defun hyprland-zen--client-address (client)
  "Return normalized address for CLIENT alist, or nil."
  (when-let* ((raw (hyprland-zen--field client 'address)))
    (hyprland--normalize-address raw)))

(defun hyprland-zen--best-match-addresses-by-title (title &optional clients)
  "Return addresses with highest title-match score for TITLE.

When TITLE is empty or no browser client matches, return nil."
  (let* ((target (hyprland-zen--string title))
         (pool (or clients (hyprland-zen--browser-clients)))
         (best-score 0)
         addresses)
    (unless (string-empty-p target)
      (dolist (client pool)
        (let* ((score (hyprland-zen--title-match-score
                       (hyprland-zen--field client 'title)
                       target))
               (address (hyprland-zen--client-address client)))
          (when (and (stringp address)
                     (not (string-empty-p address))
                     (> score 0))
            (cond
             ((> score best-score)
              (setq best-score score
                    addresses (list address)))
             ((= score best-score)
              (push address addresses)))))))
    (cl-delete-duplicates (nreverse addresses) :test #'string=)))

(defun hyprland-zen--address-intersection (lhs rhs)
  "Return string-set intersection of address lists LHS and RHS."
  (let ((rhs-set (make-hash-table :test #'equal))
        out)
    (dolist (it rhs)
      (puthash it t rhs-set))
    (dolist (it lhs)
      (when (gethash it rhs-set)
        (push it out)))
    (cl-delete-duplicates (nreverse out) :test #'string=)))

(defun hyprland-zen--address-present-p (address clients)
  "Return non-nil when ADDRESS appears in CLIENTS list."
  (cl-some (lambda (client)
             (string= (hyprland-zen--string address)
                      (hyprland-zen--string (hyprland-zen--client-address client))))
           clients))

(defun hyprland-zen--resolve-post-activate-address (keyword1-addresses target-title)
  "Resolve jump address from KEYWORD1-ADDRESSES and TARGET-TITLE.

KEYWORD1-ADDRESSES come from pre-activate window-title matching.
TARGET-TITLE provides post-activate title matching candidates."
  (let* ((clients (hyprland-zen--browser-clients))
         (k1 (cl-delete-duplicates (copy-sequence (or keyword1-addresses nil)) :test #'string=))
         (k2 (hyprland-zen--best-match-addresses-by-title target-title clients)))
    (setq hyprland-zen--last-keyword2-title (hyprland-zen--string target-title)
          hyprland-zen--last-keyword2-addresses (copy-sequence (or k2 nil))
          hyprland-zen--last-jump-address nil
          hyprland-zen--last-jump-strategy nil)
    (cond
     ((= (length k1) 1)
      (let ((only (car k1)))
        (when (hyprland-zen--address-present-p only clients)
          (setq hyprland-zen--last-jump-address only
                hyprland-zen--last-jump-strategy 'keyword1-unique)
          only)))
     ((> (length k1) 1)
      (let ((hits (hyprland-zen--address-intersection k1 k2)))
        (when (= (length hits) 1)
          (setq hyprland-zen--last-jump-address (car hits)
                hyprland-zen--last-jump-strategy 'keyword1-keyword2-intersection)
          (car hits))))
     ((= (length k2) 1)
      (setq hyprland-zen--last-jump-address (car k2)
            hyprland-zen--last-jump-strategy 'keyword2-unique)
      (car k2))
     (t nil))))

(defun hyprland-zen--jump-to-known-window (keyword1-addresses target-title)
  "Jump by keyword matching strategy.

KEYWORD1-ADDRESSES are pre-activate matches; TARGET-TITLE is post-activate tab
title used as keyword2."
  (when (and hyprland-zen-jump-to-window-on-tab-switch
             hyprland-zen-jump-match-by-title
             (fboundp 'hyprland-jump))
    (when-let* ((address (hyprland-zen--resolve-post-activate-address keyword1-addresses target-title)))
      (condition-case _err
          (progn
            (hyprland-jump address)
            t)
        (error nil)))))

(defun hyprland-zen--keyword1-addresses-for-window (window-id &optional target-tab-id)
  "Return pre-activate keyword1 candidate addresses for WINDOW-ID."
  (let (title matches)
    (setq title (hyprland-zen--active-hyprland-window-title)
          matches (hyprland-zen--best-match-addresses-by-title title))
    (unless matches
      (unless (hyprland-zen--active-tab-for-window window-id)
        (when (hyprland-zen-running-p)
          (ignore-errors
            (hyprland-zen-refresh)
            (hyprland-zen--wait-for-tabs 0.35))))
      (setq title
            (or (when-let* ((tab (hyprland-zen--active-tab-for-window window-id)))
                  (hyprland-zen--field tab 'title))
                (when-let* ((tab (hyprland-zen--tab-in-window window-id target-tab-id)))
                  (hyprland-zen--field tab 'title)))
            matches (hyprland-zen--best-match-addresses-by-title title)))
    (setq hyprland-zen--last-keyword1-title (hyprland-zen--string title)
          hyprland-zen--last-keyword1-addresses (copy-sequence (or matches nil)))
    matches))

(defun hyprland-zen--post-activate-window-sync (_window-id tab-title keyword1-addresses)
  "After activate-tab, resolve and jump using keyword matching."
  (hyprland-zen--jump-to-known-window keyword1-addresses tab-title))

(defun hyprland-zen--schedule-post-activate-window-sync (window-id tab-title keyword1-addresses)
  "Schedule delayed post-activate sync for WINDOW-ID and TAB-TITLE."
  (when (and hyprland-zen-jump-to-window-on-tab-switch
             (stringp window-id)
             (not (string-empty-p window-id)))
    (run-at-time (max 0.0 hyprland-zen-post-activate-jump-delay)
                 nil
                 #'hyprland-zen--post-activate-window-sync
                 window-id
                 tab-title
                 keyword1-addresses)))

(defun hyprland-zen--decode-image-data-url (data-url)
  "Decode DATA-URL image string into plist `(:bytes :type)'."
  (when (and (stringp data-url)
             (string-match "\\`data:image/\\([A-Za-z0-9.+-]+\\);base64,\\(.+\\)\\'" data-url))
    (let* ((raw-type (downcase (match-string 1 data-url)))
           (image-type (pcase raw-type
                         ((or "jpg" "jpeg") 'jpeg)
                         ("png" 'png)
                         (_ nil)))
           (body (match-string 2 data-url)))
      (when image-type
        (condition-case _err
            (list :bytes (base64-decode-string body)
                  :type image-type)
          (error nil))))))

(defun hyprland-zen--display-preview-message (message)
  "Display textual preview MESSAGE using shared preview UI."
  (hyprland-preview-ui-display (list :ok nil :message message)))

(defun hyprland-zen--display-preview-data-url (data-url)
  "Display image preview from DATA-URL using shared preview UI."
  (if-let* ((decoded (hyprland-zen--decode-image-data-url data-url)))
      (hyprland-preview-ui-display
       (list :ok t
             :image-bytes (plist-get decoded :bytes)
             :image-type (plist-get decoded :type)))
    (hyprland-zen--display-preview-message "Tab preview decode failed")))

(defun hyprland-zen--preview-cache-get (tab-id url)
  "Return cached DATA-URL for TAB-ID and URL when still fresh."
  (when-let* ((entry (gethash tab-id hyprland-zen--preview-cache))
              (ts (plist-get entry :ts))
              (cached-url (or (plist-get entry :url) ""))
              (data-url (plist-get entry :image-data-url)))
    (if (and (string= cached-url (or url ""))
             (<= (- (hyprland-zen--now) ts) hyprland-zen-preview-cache-ttl))
        data-url
      (remhash tab-id hyprland-zen--preview-cache)
      nil)))

(defun hyprland-zen--preview-cache-put (tab-id url data-url)
  "Store preview DATA-URL for TAB-ID and URL in short-lived cache."
  (when (and (stringp tab-id)
             (not (string-empty-p tab-id))
             (stringp data-url)
             (not (string-empty-p data-url)))
    (puthash tab-id
             (list :ts (hyprland-zen--now)
                   :url (or url "")
                   :image-data-url data-url)
             hyprland-zen--preview-cache)))

(defun hyprland-zen--reset-preview-flow-state ()
  "Reset ephemeral preview request state used by completion preview."
  (setq hyprland-zen--preview-tab-id nil
        hyprland-zen--preview-candidates nil
        hyprland-zen--preview-inflight-tab-id nil
        hyprland-zen--preview-pending-tab-id nil
        hyprland-zen--preview-pending-url nil)
  (clrhash hyprland-zen--preview-request-url))

(defun hyprland-zen--drain-preview-request-queue ()
  "Send newest queued preview request when no capture is in flight."
  (when (and (null hyprland-zen--preview-inflight-tab-id)
             (stringp hyprland-zen--preview-pending-tab-id)
             (not (string-empty-p hyprland-zen--preview-pending-tab-id)))
    (let ((tab-id hyprland-zen--preview-pending-tab-id)
          (url (or hyprland-zen--preview-pending-url "")))
      (setq hyprland-zen--preview-pending-tab-id nil
            hyprland-zen--preview-pending-url nil)
      (setq hyprland-zen--preview-inflight-tab-id tab-id)
      (puthash tab-id url hyprland-zen--preview-request-url)
      (condition-case err
          (hyprland-zen--send `((op . "capture-tab")
                                (tab_id . ,tab-id)))
        (error
         (setq hyprland-zen--preview-inflight-tab-id nil)
         (when (and (string= tab-id (or hyprland-zen--preview-tab-id ""))
                    (not (string-empty-p (or hyprland-zen--preview-tab-id ""))))
           (hyprland-zen--display-preview-message
            (format "Preview request failed: %s" (error-message-string err))))
         (hyprland-zen--drain-preview-request-queue))))))

(defun hyprland-zen--enqueue-preview-request (tab-id url)
  "Schedule preview capture for TAB-ID and URL.

Only one request is in flight; when busy, keep the latest request only."
  (cond
   ((and (stringp hyprland-zen--preview-inflight-tab-id)
         (string= hyprland-zen--preview-inflight-tab-id tab-id))
    nil)
   (hyprland-zen--preview-inflight-tab-id
    (setq hyprland-zen--preview-pending-tab-id tab-id
          hyprland-zen--preview-pending-url (or url "")))
   (t
    (setq hyprland-zen--preview-pending-tab-id tab-id
          hyprland-zen--preview-pending-url (or url ""))
    (hyprland-zen--drain-preview-request-queue))))

(defun hyprland-zen--capturable-url-p (url)
  "Return non-nil when URL is likely capturable via browser screenshot APIs."
  (let ((u (hyprland-zen--string url)))
    (or (string-empty-p u)
        (string-prefix-p "http://" u)
        (string-prefix-p "https://" u)
        (string-prefix-p "file://" u))))

(defun hyprland-zen--wait-for-bridge (&optional timeout)
  "Wait for bridge connectivity and snapshots up to TIMEOUT seconds."
  (let ((deadline (+ (hyprland-zen--now) (or timeout hyprland-zen-initial-sync-timeout))))
    (while (and (hyprland-zen-running-p)
                (not hyprland-zen--bridge-connected)
                (< (hyprland-zen--now) deadline))
      (accept-process-output hyprland-zen--process 0.12))
    hyprland-zen--bridge-connected))

(defun hyprland-zen--preview-state (action cand)
  "Consult state callback for Zen tab preview.

ACTION and CAND follow Consult's :state contract."
  (pcase action
    ('setup nil)
    ('preview
     (if (not cand)
         (hyprland-zen--display-preview-message "No tab candidate")
       (let* ((tab (hyprland-zen--resolve-selection cand hyprland-zen--preview-candidates 'tab_id))
              (tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id)))
              (url (hyprland-zen--string (hyprland-zen--field tab 'url))))
         (if (string-empty-p tab-id)
             (hyprland-zen--display-preview-message "Candidate missing tab metadata")
           (if (not (hyprland-zen--capturable-url-p url))
               (hyprland-zen--display-preview-message
                (format "Preview unavailable for this page type: %s" (if (string-empty-p url) "<unknown>" url)))
             (setq hyprland-zen--preview-tab-id tab-id)
             (if-let* ((cached (hyprland-zen--preview-cache-get tab-id url)))
                 (hyprland-zen--display-preview-data-url cached)
               (hyprland-zen--enqueue-preview-request tab-id url)))))))
    ((or 'exit 'return)
     (hyprland-zen--reset-preview-flow-state)
     (hyprland-preview-ui-cleanup))))

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

(defun hyprland-zen--bridge-disconnect-message-p (message)
  "Return non-nil when MESSAGE indicates transient bridge disconnection."
  (and (stringp message)
       (or (string-match-p "browser-bridge-not-connected" message)
           (string-match-p "browser-bridge-disconnected" message))))

(defun hyprland-zen--clear-bridge-disconnect-error ()
  "Clear stale disconnect diagnostics when bridge has recovered."
  (when (and (stringp hyprland-zen--last-error-message)
             (or (string-match-p "browser-bridge-not-connected" hyprland-zen--last-error-message)
                 (string-match-p "browser-bridge-disconnected" hyprland-zen--last-error-message)))
    (setq hyprland-zen--last-error-message nil
          hyprland-zen--last-error-op nil)))

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
        hyprland-zen--last-sentinel-event nil
        hyprland-zen--bridge-connected nil
        hyprland-zen--bridge-last-reason nil
        hyprland-zen--queued-op-count 0
        hyprland-zen--last-queued-op nil
        hyprland-zen--queued-event-serial 0
        hyprland-zen--last-keyword1-title nil
        hyprland-zen--last-keyword1-addresses nil
        hyprland-zen--last-keyword2-title nil
        hyprland-zen--last-keyword2-addresses nil
        hyprland-zen--last-jump-address nil
        hyprland-zen--last-jump-strategy nil
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

(defun hyprland-zen--ensure-tabs-ready ()
  "Ensure host is running and attempt to populate tab snapshot.

Return current tab list (possibly empty)."
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start))
  (or (hyprland-zen-tabs)
      (let (tabs)
        (dotimes (_attempt 3)
          (when (null tabs)
            (hyprland-zen-refresh)
            (hyprland-zen-refresh-workspaces)
            (setq tabs (hyprland-zen--wait-for-tabs 1.2))
            (when (and (null tabs) (hyprland-zen-running-p))
              (hyprland-zen--wait-for-bridge 1.2))))
        ;; Last resort: recycle local line-stdio bridge process once.
        (when (and (null tabs)
                   (hyprland-zen-running-p)
                   (not hyprland-zen--bridge-connected))
          (hyprland-zen-stop)
          (hyprland-zen-start)
          (hyprland-zen-refresh)
          (hyprland-zen-refresh-workspaces)
          (setq tabs (hyprland-zen--wait-for-tabs 1.6)))
        (when (and (null tabs)
                   (not (hyprland-zen-running-p)))
          (hyprland-zen-start)
          (when (hyprland-zen-running-p)
            (hyprland-zen-refresh)
            (hyprland-zen-refresh-workspaces)
            (setq tabs (hyprland-zen--wait-for-tabs 1.6))))
        tabs)))

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
  (hyprland-zen--string (hyprland-zen--field tab 'workspace_id) "default"))

(defun hyprland-zen--workspace-friendly-name (workspace-id)
  "Return user-facing workspace name derived from WORKSPACE-ID when possible."
  (let ((raw (hyprland-zen--string workspace-id)))
    (cond
     ((string-match "\\`win:\\(.+\\)\\'" raw)
      (format "Window %s" (hyprland-zen--string (match-string 1 raw))))
     (t raw))))

(defun hyprland-zen--workspace-name-from-tab (tab)
  "Extract workspace display name from TAB payload."
  (let* ((raw (hyprland-zen--field tab 'workspace_name))
         (workspace-id (hyprland-zen--workspace-id-from-tab tab))
         (name (hyprland-zen--string raw)))
    (if (string-empty-p name)
        (hyprland-zen--workspace-friendly-name workspace-id)
      name)))

(defun hyprland-zen--normalize-workspace (workspace)
  "Normalize WORKSPACE alist shape used by the workspace store."
  (let* ((browser (hyprland-zen--string (hyprland-zen--field workspace 'browser) "zen"))
         (profile (hyprland-zen--string (hyprland-zen--field workspace 'profile) "default"))
         (workspace-id
          (hyprland-zen--string
           (hyprland-zen--field workspace 'workspace_id)
           "default"))
         (name
          (hyprland-zen--string
           (or (hyprland-zen--field workspace 'name)
               (hyprland-zen--field workspace 'title)
               (hyprland-zen--workspace-friendly-name workspace-id))
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
         (cookie-store (hyprland-zen--string (hyprland-zen--field tab 'cookie_store_id) "default"))
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
  (clrhash hyprland-zen--workspaces))

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
  (downcase (hyprland-zen--string (hyprland-zen--field message 'type))))

(defun hyprland-zen--remove-message-key (message)
  "Extract tab key from MESSAGE remove payload."
  (hyprland-zen--field message 'key))

(defun hyprland-zen--remove-workspace-key (message)
  "Extract workspace key from MESSAGE remove payload."
  (hyprland-zen--field message 'key))

(defun hyprland-zen--apply-message (message)
  "Apply parsed host MESSAGE to in-memory state."
  (let ((type (hyprland-zen--message-type message)))
    (hyprland-zen--touch-line type)
    (hyprland-zen--trace-add 'in message)
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
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t)
      ("workspace_snapshot"
       (setq hyprland-zen--last-workspace-snapshot-at hyprland-zen--last-line-at)
       (setq hyprland-zen--bridge-connected t)
       (hyprland-zen--clear-bridge-disconnect-error)
       (clrhash hyprland-zen--workspaces)
       (dolist (workspace (or (hyprland-zen--field message 'workspaces) nil))
         (hyprland-zen--store-workspace workspace))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t)
      ("upsert"
       (when-let* ((tab (or (hyprland-zen--field message 'tab)
                            message))
                   (stored (hyprland-zen--store-tab tab)))
         (run-hooks 'hyprland-zen-after-refresh-hook)
         t))
      ("workspace-upsert"
       (when-let* ((workspace (or (hyprland-zen--field message 'workspace)
                                  message)))
         (hyprland-zen--store-workspace workspace)
         (run-hooks 'hyprland-zen-after-refresh-hook)
         t))
      ("bridge-state"
       (setq hyprland-zen--bridge-connected
             (hyprland-zen--truthy-p (hyprland-zen--field message 'connected))
             hyprland-zen--bridge-last-reason
             (hyprland-zen--string (hyprland-zen--field message 'reason)))
       (when hyprland-zen--bridge-connected
         (setq hyprland-zen--queued-op-count 0)
         (hyprland-zen--clear-bridge-disconnect-error)
         (hyprland-zen--drain-preview-request-queue))
       (when (and hyprland-zen--bridge-connected
                  (hyprland-zen-running-p)
                  (or (= (hash-table-count hyprland-zen--tabs) 0)
                      (= (hash-table-count hyprland-zen--workspaces) 0)))
         (ignore-errors
           (hyprland-zen-refresh)
           (hyprland-zen-refresh-workspaces)))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       t)
      ("queued"
       (setq hyprland-zen--bridge-connected nil
             hyprland-zen--last-queued-op
             (hyprland-zen--string (hyprland-zen--field message 'op))
             hyprland-zen--queued-op-count
             (max 1
                  (or (and (numberp (hyprland-zen--field message 'queue_length))
                           (hyprland-zen--field message 'queue_length))
                      (1+ hyprland-zen--queued-op-count))))
       (cl-incf hyprland-zen--queued-event-serial)
       (when (and (string= hyprland-zen--last-queued-op "capture-tab")
                  (stringp hyprland-zen--preview-inflight-tab-id)
                  (not (string-empty-p hyprland-zen--preview-inflight-tab-id)))
         (let* ((tab-id hyprland-zen--preview-inflight-tab-id)
                (url (gethash tab-id hyprland-zen--preview-request-url "")))
           (setq hyprland-zen--preview-inflight-tab-id nil
                 hyprland-zen--preview-pending-tab-id tab-id
                 hyprland-zen--preview-pending-url (or url ""))))
       (when-let* ((reason (hyprland-zen--string (hyprland-zen--field message 'message))))
         (hyprland-zen--record-error reason (hyprland-zen--field message 'op)))
       (run-hooks 'hyprland-zen-after-refresh-hook)
       nil)
      ("remove"
       (when-let* ((key (hyprland-zen--remove-message-key message)))
         (hyprland-zen--remove-tab-by-key key)
         (run-hooks 'hyprland-zen-after-refresh-hook)
         t))
      ("workspace-remove"
       (when-let* ((key (hyprland-zen--remove-workspace-key message)))
         (remhash key hyprland-zen--workspaces)
         (run-hooks 'hyprland-zen-after-refresh-hook)
         t))
      ("preview"
       (let ((tab-id (hyprland-zen--string (hyprland-zen--field message 'tab_id))))
         (setq hyprland-zen--last-preview-response-at hyprland-zen--last-line-at)
         (when (and (stringp hyprland-zen--preview-inflight-tab-id)
                    (string= tab-id hyprland-zen--preview-inflight-tab-id))
           (setq hyprland-zen--preview-inflight-tab-id nil))
         (when-let* ((data-url (hyprland-zen--string (hyprland-zen--field message 'image_data_url))))
           (hyprland-zen--preview-cache-put tab-id (gethash tab-id hyprland-zen--preview-request-url "") data-url)
           (remhash tab-id hyprland-zen--preview-request-url))
         (hyprland-zen--drain-preview-request-queue)
         (when (and hyprland-zen--preview-tab-id
                    (string= tab-id hyprland-zen--preview-tab-id))
           (hyprland-zen--display-preview-data-url
            (hyprland-zen--string (hyprland-zen--field message 'image_data_url)))
           t)))
      ("error"
       (hyprland-zen--record-error
        (hyprland-zen--field message 'message)
        (hyprland-zen--field message 'op))
       (when (hyprland-zen--bridge-disconnect-message-p hyprland-zen--last-error-message)
         (setq hyprland-zen--bridge-connected nil))
       (when (string= (hyprland-zen--string (hyprland-zen--field message 'op)) "capture-tab")
         (setq hyprland-zen--preview-inflight-tab-id nil)
         (hyprland-zen--drain-preview-request-queue))
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
    (hyprland-zen--reset-preview-flow-state)
    (setq hyprland-zen--process nil
          hyprland-zen--fragment ""
          hyprland-zen--bridge-connected nil
          hyprland-zen--bridge-last-reason "host-process-exited"
          hyprland-zen--queued-op-count 0
          hyprland-zen--last-queued-op nil)))

(defun hyprland-zen-running-p ()
  "Return non-nil when Zen host process is running."
  (and (process-live-p hyprland-zen--process) t))

(defun hyprland-zen--wait-for-queued-op (op baseline-serial &optional timeout)
  "Wait for queued event of OP after BASELINE-SERIAL up to TIMEOUT seconds."
  (let ((deadline (+ (hyprland-zen--now) (or timeout 0.45)))
        seen)
    (while (and (hyprland-zen-running-p)
                (not (setq seen (and (> hyprland-zen--queued-event-serial baseline-serial)
                                     (string= (or hyprland-zen--last-queued-op "") op))))
                (< (hyprland-zen--now) deadline))
      (accept-process-output hyprland-zen--process 0.08))
    seen))

(defun hyprland-zen--send-with-queued-retry (payload &optional retry-timeout)
  "Send PAYLOAD and retry once when it is queued during reconnect window."
  (let* ((op (hyprland-zen--string (hyprland-zen--field payload 'op)))
         (baseline hyprland-zen--queued-event-serial))
    (hyprland-zen--send payload)
    (when (and (hyprland-zen--wait-for-queued-op op baseline)
               (hyprland-zen--wait-for-bridge (or retry-timeout hyprland-zen-op-retry-timeout)))
      (hyprland-zen--send payload))))

(defun hyprland-zen--send (payload)
  "Send JSON PAYLOAD to running host process."
  (unless (hyprland-zen-running-p)
    (hyprland-zen-start)
    (unless (hyprland-zen-running-p)
      (user-error "hyprland-zen host is not running")))
  (hyprland-zen--trace-add 'out payload)
  (cl-incf hyprland-zen--messages-out)
  (when (equal (hyprland-zen--field payload 'op) "capture-tab")
    (setq hyprland-zen--last-preview-request-at (hyprland-zen--now)))
  (process-send-string hyprland-zen--process
                       (concat (json-encode payload) "\n")))

(defun hyprland-zen--socket-conflict-detected-p ()
  "Return non-nil when recent host output indicates socket ownership conflict."
  (cl-some (lambda (entry)
             (and (eq (plist-get entry :dir) 'parse-error)
                  (string-match-p
                   "hyprland-zen-native-host already running"
                   (hyprland-zen--string (plist-get entry :payload)))))
           (cl-subseq hyprland-zen--trace 0 (min (length hyprland-zen--trace) 6))))

(defun hyprland-zen--recover-startup-socket-conflict ()
  "Try to clear stale line-stdio host and return non-nil on success."
  (and (executable-find "pkill")
       (stringp hyprland-zen-line-host-pkill-pattern)
       (> (length (string-trim hyprland-zen-line-host-pkill-pattern)) 0)
       (progn
         (call-process "pkill" nil nil nil "-f" hyprland-zen-line-host-pkill-pattern)
         t)))

(defun hyprland-zen--start-process (resolved)
  "Start line-stdio host process using RESOLVED command list."
  (make-process
   :name "hyprland-zen-bridge"
   :command resolved
   :buffer nil
   :noquery t
   :connection-type 'pipe
   :coding 'utf-8-unix
   :filter #'hyprland-zen--process-filter
   :sentinel #'hyprland-zen--process-sentinel))

(defun hyprland-zen--await-startup-settle (&optional timeout)
  "Wait briefly so startup sentinel/parse output has time to arrive."
  (let ((deadline (+ (hyprland-zen--now) (or timeout 0.45))))
    (while (and (hyprland-zen-running-p)
                (< (hyprland-zen--now) deadline))
      (accept-process-output hyprland-zen--process 0.08))))

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
      (setq hyprland-zen--process (hyprland-zen--start-process resolved))
      ;; Let early startup output/sentinel settle before first refresh.
      (hyprland-zen--await-startup-settle)
      (when (and (not (hyprland-zen-running-p))
                 hyprland-zen-recover-startup-socket-conflict
                 (hyprland-zen--socket-conflict-detected-p)
                 (hyprland-zen--recover-startup-socket-conflict))
        (setq hyprland-zen--process (hyprland-zen--start-process resolved))
        (hyprland-zen--await-startup-settle))
      (when (and hyprland-zen-auto-refresh-on-start
                 (hyprland-zen-running-p))
        (hyprland-zen-refresh)
        (hyprland-zen-refresh-workspaces))
      hyprland-zen--process)))

(defun hyprland-zen-stop ()
  "Stop Zen native host process."
  (interactive)
  (when (process-live-p hyprland-zen--process)
    (delete-process hyprland-zen--process))
  (hyprland-zen--reset-preview-flow-state)
  (hyprland-preview-ui-cleanup)
  (setq hyprland-zen--process nil
        hyprland-zen--fragment ""))

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
                :last-keyword1-title hyprland-zen--last-keyword1-title
                :last-keyword1-addresses hyprland-zen--last-keyword1-addresses
                :last-keyword2-title hyprland-zen--last-keyword2-title
                :last-keyword2-addresses hyprland-zen--last-keyword2-addresses
                :last-jump-address hyprland-zen--last-jump-address
                :last-jump-strategy hyprland-zen--last-jump-strategy
                :last-error-op hyprland-zen--last-error-op
                :last-error-message hyprland-zen--last-error-message
                :last-sentinel-event hyprland-zen--last-sentinel-event)))
    (when (called-interactively-p 'interactive)
      (message
       "Zen bridge: running=%s bridge=%s reason=%s tabs=%d workspaces=%d in/out=%d/%d trace=%d last=%s %.1fs ago err=%s"
       (if running "yes" "no")
       (if hyprland-zen--bridge-connected "connected" "disconnected")
       (or hyprland-zen--bridge-last-reason "none")
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
  (when (called-interactively-p 'interactive)
    (unless (or hyprland-zen--bridge-connected
                (hyprland-zen--wait-for-bridge 1.2))
      (user-error "Zen bridge is reconnecting; retry in a moment (M-x hyprland-zen-doctor)")))
  (hyprland-zen--send-with-queued-retry
   `((op . "open-url")
     (url . ,url))
   hyprland-zen-op-retry-timeout))

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
       "No Zen tabs available (bridge=%s reason=%s). Check `M-x hyprland-zen-status' / `M-x hyprland-zen-doctor'"
       (if hyprland-zen--bridge-connected "connected" "disconnected")
       (or hyprland-zen--bridge-last-reason "none")))
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
        tab))))

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
         (tab-title (hyprland-zen--string (hyprland-zen--field target 'title)))
         (tab-id (hyprland-zen--string (hyprland-zen--field target 'tab_id)))
         (keyword1-addresses (hyprland-zen--keyword1-addresses-for-window window-id tab-id))
         (workspace-id (hyprland-zen--string (hyprland-zen--field target 'workspace_id)))
         (sync-group (hyprland-zen--string (hyprland-zen--field target 'sync_group)))
         (payload `((op . "activate-tab")
                    (key . ,key)
                    (tab_id . ,tab-id)
                    (window_id . ,window-id)
                    (workspace_id . ,workspace-id)
                    (sync_group . ,sync-group))))
    (when (called-interactively-p 'interactive)
      (unless (or hyprland-zen--bridge-connected
                  (hyprland-zen--wait-for-bridge 1.5))
        (user-error "Zen bridge is reconnecting; activate-tab aborted")))
    (hyprland-zen--send-with-queued-retry payload hyprland-zen-op-retry-timeout)
    (when window-id
      (hyprland-zen--schedule-post-activate-window-sync
       window-id tab-title keyword1-addresses))
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
    (when (called-interactively-p 'interactive)
      (unless (or hyprland-zen--bridge-connected
                  (hyprland-zen--wait-for-bridge 1.5))
        (user-error "Zen bridge is reconnecting; activate-workspace aborted")))
    (hyprland-zen--send-with-queued-retry
     `((op . "activate-workspace")
       (key . ,key))
     hyprland-zen-op-retry-timeout)
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
