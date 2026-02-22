;;; hyprland-preview.el --- Screenshot preview helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Async static preview capture via grim -T with single-flight semantics.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)

(defvar hyprland-preview--cache (make-hash-table :test #'equal))
(defvar hyprland-preview--cache-bytes 0)
(defvar hyprland-preview--active-process nil)
(defvar hyprland-preview--active-token 0)
(defvar hyprland-preview--active-restore-address nil)

(defcustom hyprland-preview-overlay-cursor nil
  "When non-nil, include cursor in grim captures."
  :type 'boolean
  :group 'hyprland)

(defcustom hyprland-preview-ttl-seconds 20
  "Maximum age of cached previews in seconds."
  :type 'integer
  :group 'hyprland)

(defcustom hyprland-preview-cache-max-entries 24
  "Maximum number of in-memory preview entries.

Older entries are evicted first when the limit is exceeded."
  :type 'integer
  :group 'hyprland)

(defcustom hyprland-preview-cache-max-bytes (* 64 1024 1024)
  "Maximum total bytes kept in the in-memory preview cache.

Older entries are evicted first when the limit is exceeded."
  :type 'integer
  :group 'hyprland)

(defcustom hyprland-preview-focus-for-accurate-capture nil
  "When non-nil, temporarily focus hidden/off-workspace window before capture.

Wayland screencopy captures visible composition.  For hidden, stacked, or
off-workspace windows, this option improves correctness by focusing target
window briefly and restoring prior focus after capture."
  :type 'boolean
  :group 'hyprland)

(defcustom hyprland-preview-focus-settle-ms 60
  "Delay after focus switch before screenshot capture starts."
  :type 'integer
  :group 'hyprland)

(defun hyprland-preview--now ()
  "Return current monotonic seconds as float."
  (float-time))

(defun hyprland-preview-cache-clear ()
  "Clear in-memory preview cache and optional disk cache files."
  (interactive)
  (clrhash hyprland-preview--cache)
  (setq hyprland-preview--cache-bytes 0)
  (when (and (eq hyprland-preview-cache-mode 'disk)
             (file-directory-p hyprland-preview-cache-directory))
    (dolist (f (directory-files hyprland-preview-cache-directory t "\\`[^.]"))
      (when (file-regular-p f)
        (delete-file f)))))

(defun hyprland-preview--sensitive-p (window)
  "Return non-nil when WINDOW matches sensitive preview regex."
  (when hyprland-preview-sensitive-regexp
    (let ((title (or (alist-get 'title window) ""))
          (class (or (alist-get 'class window) "")))
      (or (string-match-p hyprland-preview-sensitive-regexp title)
          (string-match-p hyprland-preview-sensitive-regexp class)))))

(defun hyprland-preview--address->identifier (address)
  "Convert Hyprland window ADDRESS to grim -T identifier string.

Identifier is lower-case 16-digit hex without 0x prefix."
  (let* ((normalized (hyprland--normalize-address address))
         (raw (and normalized (downcase (string-trim normalized)))))
    (when (and raw (string-match-p "\\`0x[0-9a-f]+\\'" raw))
      (format "%016x" (string-to-number (substring raw 2) 16)))))

(defun hyprland-preview--cache-key (window)
  "Build preview cache key for WINDOW."
  (format "%s|%s|%s|%s|%s"
          (or (hyprland--instance-signature) "")
          (or (alist-get 'address window) "")
          "grim-t"
          (sxhash (or (alist-get 'title window) ""))
          (or (alist-get 'size window) "")))

(defun hyprland-preview--cache-get (key)
  "Return cached preview data for KEY if still fresh."
  (when-let* ((entry (gethash key hyprland-preview--cache)))
    (if (<= (- (hyprland-preview--now) (plist-get entry :ts)) hyprland-preview-ttl-seconds)
        (plist-get entry :png-bytes)
      (remhash key hyprland-preview--cache)
      (setq hyprland-preview--cache-bytes
            (max 0 (- hyprland-preview--cache-bytes (or (plist-get entry :bytes) 0))))
      nil)))

(defun hyprland-preview--cache-prune ()
  "Evict stale/old entries to enforce memory cache bounds."
  (let ((now (hyprland-preview--now))
        (entries nil))
    (maphash
     (lambda (key entry)
       (if (> (- now (plist-get entry :ts)) hyprland-preview-ttl-seconds)
           (progn
             (remhash key hyprland-preview--cache)
             (setq hyprland-preview--cache-bytes
                   (max 0 (- hyprland-preview--cache-bytes (or (plist-get entry :bytes) 0)))))
         (push (list key (plist-get entry :ts) (or (plist-get entry :bytes) 0)) entries)))
     hyprland-preview--cache)
    (setq entries (sort entries (lambda (a b) (< (nth 1 a) (nth 1 b)))))
    (while (and entries
                (or (> (hash-table-count hyprland-preview--cache) (max 1 hyprland-preview-cache-max-entries))
                    (> hyprland-preview--cache-bytes (max 1 hyprland-preview-cache-max-bytes))))
      (let* ((item (pop entries))
             (key (nth 0 item))
             (bytes (nth 2 item)))
        (remhash key hyprland-preview--cache)
        (setq hyprland-preview--cache-bytes (max 0 (- hyprland-preview--cache-bytes bytes)))))))

(defun hyprland-preview--cache-put (key png-bytes)
  "Store PNG-BYTES in cache under KEY."
  (when-let* ((old (gethash key hyprland-preview--cache)))
    (setq hyprland-preview--cache-bytes
          (max 0 (- hyprland-preview--cache-bytes (or (plist-get old :bytes) 0)))))
  (let ((bytes (string-bytes png-bytes)))
    (puthash key (list :ts (hyprland-preview--now) :bytes bytes :png-bytes png-bytes)
             hyprland-preview--cache)
    (setq hyprland-preview--cache-bytes (+ hyprland-preview--cache-bytes bytes)))
  (hyprland-preview--cache-prune)
  (when (eq hyprland-preview-cache-mode 'disk)
    (make-directory hyprland-preview-cache-directory t)
    (set-file-modes hyprland-preview-cache-directory #o700)
    (let ((path (expand-file-name (format "%s.png" (md5 key)) hyprland-preview-cache-directory)))
      (with-temp-file path
        (set-buffer-multibyte nil)
        (insert png-bytes))
      (set-file-modes path #o600))))

(defun hyprland-preview--usable-executable-p (path)
  "Return non-nil when PATH points to a non-empty executable file."
  (when (and (stringp path) (file-executable-p path) (file-regular-p path))
    (let ((attrs (file-attributes path 'string)))
      (and attrs (> (file-attribute-size attrs) 0)))))

(defun hyprland-preview--capture-args (window)
  "Return grim command args for capturing WINDOW preview.

Signal an error when window address cannot be converted into grim identifier."
  (let ((identifier (hyprland-preview--address->identifier (alist-get 'address window))))
    (unless identifier
      (error "Window missing valid address for grim -T capture"))
    (append (when hyprland-preview-overlay-cursor (list "-c"))
            (list "-T" identifier "-"))))

(defun hyprland-preview--grim-command (window)
  "Build grim command plist for WINDOW, or nil when args cannot be formed."
  (condition-case nil
      (list :program hyprland-grim-executable
            :args (hyprland-preview--capture-args window))
    (error nil)))

(defun hyprland-preview--cancel-active-process ()
  "Cancel the currently active capture process, if any."
  (when (process-live-p hyprland-preview--active-process)
    (delete-process hyprland-preview--active-process))
  (setq hyprland-preview--active-process nil)
  (hyprland-preview--restore-focus))

(defun hyprland-preview-cancel ()
  "Cancel the active preview request and invalidate in-flight callbacks."
  (hyprland-preview--cancel-active-process)
  (cl-incf hyprland-preview--active-token))

(defun hyprland-preview--active-window-address ()
  "Return normalized address for current active window, or nil."
  (condition-case nil
      (when-let* ((active (hyprland--hyprctl-json "activewindow"))
                  (address (alist-get 'address active)))
        (hyprland--normalize-address address))
    (error nil)))

(defun hyprland-preview--active-workspace-id ()
  "Return active workspace id, or nil when unavailable."
  (condition-case nil
      (when-let* ((active (hyprland--hyprctl-json "activeworkspace"))
                  (id (alist-get 'id active)))
        id)
    (error nil)))

(defun hyprland-preview--window-workspace-id (window)
  "Return workspace id for WINDOW alist, or nil."
  (let ((ws (alist-get 'workspace window)))
    (and (listp ws) (alist-get 'id ws))))

(defun hyprland-preview--hidden-window-p (window)
  "Return non-nil if WINDOW is marked hidden."
  (let ((hidden (alist-get 'hidden window)))
    (or (eq hidden t)
        (eq hidden 1)
        (equal hidden "1"))))

(defun hyprland-preview--needs-focus-for-capture-p (window)
  "Return non-nil when WINDOW likely needs focus for accurate screenshot."
  (or (hyprland-preview--hidden-window-p window)
      (let ((wid (hyprland-preview--window-workspace-id window))
            (aid (hyprland-preview--active-workspace-id)))
        (and wid aid (not (equal wid aid))))))

(defun hyprland-preview--restore-focus ()
  "Restore focus to previously active window when recorded."
  (when (stringp hyprland-preview--active-restore-address)
    (let ((restore hyprland-preview--active-restore-address))
      (setq hyprland-preview--active-restore-address nil)
      (ignore-errors
        (hyprland--dispatch "focuswindow" (format "address:%s" restore))))))

(defun hyprland-preview--prepare-focus-for-capture (window)
  "Prepare focus for accurate capture of WINDOW.

Return non-nil when focus was switched and must later be restored."
  (when (and hyprland-preview-focus-for-accurate-capture
             (hyprland-preview--needs-focus-for-capture-p window))
    (let* ((current (hyprland-preview--active-window-address))
           (target (hyprland--normalize-address (alist-get 'address window))))
      (when (and current target (not (equal current target)))
        (ignore-errors
          (hyprland--dispatch "focuswindow" (format "address:%s" target))
          (setq hyprland-preview--active-restore-address current)
          (sleep-for (max 0.0 (/ (max 0 hyprland-preview-focus-settle-ms) 1000.0)))
          t)))))

(defun hyprland-preview-request (window callback)
  "Request screenshot preview for WINDOW, delivering to CALLBACK.

CALLBACK receives plist:
  (:ok t :png-bytes BYTES) on success
  (:ok nil :reason SYMBOL :message STR) on fallback/skip/error

Requests are single-flight: starting a new request cancels the prior one."
  (if (hyprland-preview--sensitive-p window)
      (funcall callback (list :ok nil :reason 'sensitive :message "Sensitive window"))
    (let* ((key (hyprland-preview--cache-key window))
           (cached (hyprland-preview--cache-get key)))
      (if cached
          (funcall callback (list :ok t :png-bytes cached :cached t))
        (hyprland-preview--cancel-active-process)
        (cl-incf hyprland-preview--active-token)
        (let ((token hyprland-preview--active-token)
              (command (hyprland-preview--grim-command window)))
          (if (null command)
              (funcall callback
                       (list :ok nil
                             :reason 'grim-command-unavailable
                             :message "Unable to build grim -T capture command"))
            (let* ((program (plist-get command :program))
                   (args (plist-get command :args))
                   (chunks nil))
              (hyprland-preview--prepare-focus-for-capture window)
              (let ((process
                     (condition-case err
                         (make-process
                          :name "hyprland-preview-grim"
                          :command (cons program args)
                          :buffer nil
                          :noquery t
                          :coding 'binary
                          :connection-type 'pipe
                          :filter (lambda (_proc chunk)
                                    (push chunk chunks))
                          :sentinel
                          (lambda (process _event)
                            (when (and (= token hyprland-preview--active-token)
                                       (memq (process-status process) '(exit signal)))
                              (setq hyprland-preview--active-process nil)
                              (hyprland-preview--restore-focus)
                              (if (and (eq (process-status process) 'exit)
                                       (= (process-exit-status process) 0))
                                  (let ((bytes (apply #'concat (nreverse chunks))))
                                    (hyprland-preview--cache-put key bytes)
                                    (funcall callback (list :ok t :png-bytes bytes :cached nil)))
                                (funcall callback
                                         (list :ok nil
                                               :reason 'capture-failed
                                               :message
                                               (format "grim capture exited %s"
                                                       (if (eq (process-status process) 'exit)
                                                           (process-exit-status process)
                                                         (process-status process)))))))))
                       (error
                        (setq hyprland-preview--active-process nil)
                        (hyprland-preview--restore-focus)
                        (funcall callback
                                 (list :ok nil
                                       :reason 'capture-failed
                                       :message
                                       (format "grim capture failed to start: %s"
                                               (error-message-string err))))
                        nil))))
                (when process
                  (setq hyprland-preview--active-process process))))))))))

(provide 'hyprland-preview)
;;; hyprland-preview.el ends here
