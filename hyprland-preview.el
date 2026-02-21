;;; hyprland-preview.el --- Screenshot preview helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Async static preview capture with pluggable backends and single-flight semantics.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)

(defvar hyprland-preview--grim-supports-target nil)
(defvar hyprland-preview--cache (make-hash-table :test #'equal))
(defvar hyprland-preview--active-process nil)
(defvar hyprland-preview--active-token 0)
(defvar hyprland-preview--active-restore-address nil)

(defcustom hyprland-preview-capture-backend 'auto
  "Preview capture backend.

`auto' tries toplevel helper first, then falls back to grim.
`toplevel' requires external helper (`hyprland-toplevel-snap').
`grim' uses screencopy-based grim path only."
  :type '(choice (const :tag "Auto" auto)
          (const :tag "Toplevel helper" toplevel)
          (const :tag "Grim" grim))
  :group 'hyprland)

(defcustom hyprland-preview-toplevel-helper-executable "hyprland-toplevel-snap"
  "Executable used for toplevel-export capture backend."
  :type 'string
  :group 'hyprland)

(defcustom hyprland-preview-overlay-cursor nil
  "When non-nil, include cursor in helper-based captures where supported."
  :type 'boolean
  :group 'hyprland)

(defcustom hyprland-preview-ttl-seconds 20
  "Maximum age of cached previews in seconds."
  :type 'integer
  :group 'hyprland)

(defcustom hyprland-preview-focus-for-accurate-capture t
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

(defun hyprland-preview--grim-supports-target-p ()
  "Return non-nil if `grim -h' advertises -T support."
  (or hyprland-preview--grim-supports-target
      (setq hyprland-preview--grim-supports-target
            (condition-case nil
                (string-match-p "-T" (hyprland--call-process-to-string hyprland-grim-executable "-h"))
              (error nil)))))

(defun hyprland-preview--stable-id->identifier (stable-id)
  "Convert STABLE-ID to lower-case hex string without 0x.

Return nil when conversion fails validation."
  (let ((id
         (cond
          ((integerp stable-id) (format "%x" stable-id))
          ((stringp stable-id)
           (let ((s (downcase (string-trim stable-id))))
             (if (string-prefix-p "0x" s) (substring s 2) s)))
          (t nil))))
    (when (and id (string-match-p "\\`[0-9a-f]+\\'" id))
      id)))

(defun hyprland-preview--geometry (window)
  "Return grim geometry string for WINDOW, or nil.

WINDOW should contain alist fields `at' and `size' as two-element lists."
  (let* ((at (alist-get 'at window))
         (size (alist-get 'size window)))
    (when (and (listp at) (= (length at) 2) (listp size) (= (length size) 2))
      (format "%s,%s %sx%s" (nth 0 at) (nth 1 at) (nth 0 size) (nth 1 size)))))

(defun hyprland-preview--cache-key (window)
  "Build preview cache key for WINDOW."
  (format "%s|%s|%s|%s|%s"
          (or (hyprland--instance-signature) "")
          (or (alist-get 'address window) "")
          (or (alist-get 'stable_id window) "")
          (sxhash (or (alist-get 'title window) ""))
          (or (alist-get 'size window) "")))

(defun hyprland-preview--cache-get (key)
  "Return cached preview data for KEY if still fresh."
  (when-let* ((entry (gethash key hyprland-preview--cache))
              (age (- (hyprland-preview--now) (plist-get entry :ts)))
              (_ (<= age hyprland-preview-ttl-seconds)))
    (plist-get entry :png-bytes)))

(defun hyprland-preview--cache-put (key png-bytes)
  "Store PNG-BYTES in cache under KEY."
  (puthash key (list :ts (hyprland-preview--now) :png-bytes png-bytes)
           hyprland-preview--cache)
  (when (eq hyprland-preview-cache-mode 'disk)
    (make-directory hyprland-preview-cache-directory t)
    (set-file-modes hyprland-preview-cache-directory #o700)
    (let ((path (expand-file-name (format "%s.png" (md5 key)) hyprland-preview-cache-directory)))
      (with-temp-file path
        (set-buffer-multibyte nil)
        (insert png-bytes))
      (set-file-modes path #o600))))

(defun hyprland-preview--toplevel-helper-path ()
  "Return absolute path of toplevel helper executable, or nil."
  (when (stringp hyprland-preview-toplevel-helper-executable)
    (or (executable-find hyprland-preview-toplevel-helper-executable)
        (let* ((lib (or load-file-name (locate-library "hyprland-preview")))
               (root (and lib (file-name-directory lib)))
               (local (and root (expand-file-name "tools/hyprland-toplevel-snap" root))))
          (when (and (stringp local) (file-executable-p local))
            local)))))

(defun hyprland-preview--capture-args (window)
  "Return grim command args for capturing WINDOW preview.

Prefer grim -T when supported and stable id is valid; otherwise use grim -g.
Signal an error if neither mode can be formed."
  (let ((identifier (hyprland-preview--stable-id->identifier (alist-get 'stable_id window)))
        (geometry (hyprland-preview--geometry window)))
    (cond
     ((and (hyprland-preview--grim-supports-target-p) identifier)
      (list "-T" identifier "-"))
     (geometry
      (list "-g" geometry "-"))
     (t
      (error "Unable to build grim args for preview")))))

(defun hyprland-preview--toplevel-capture-attempt (window)
  "Build toplevel helper capture attempt for WINDOW, or nil."
  (when-let* ((helper (hyprland-preview--toplevel-helper-path))
              (address (alist-get 'address window)))
    (list :backend 'toplevel
          :program helper
          :args (append (when hyprland-preview-overlay-cursor (list "--cursor"))
                        (list "--address" (hyprland--normalize-address address))))))

(defun hyprland-preview--grim-capture-attempt (window)
  "Build grim capture attempt for WINDOW, or nil when args cannot be formed."
  (condition-case nil
      (list :backend 'grim
            :program hyprland-grim-executable
            :args (hyprland-preview--capture-args window))
    (error nil)))

(defun hyprland-preview--capture-attempts (window)
  "Build ordered capture attempt list for WINDOW based on backend policy."
  (let ((helper (hyprland-preview--toplevel-capture-attempt window))
        (grim (hyprland-preview--grim-capture-attempt window)))
    (pcase hyprland-preview-capture-backend
      ('toplevel (delq nil (list helper)))
      ('grim (delq nil (list grim)))
      (_ (delq nil (list helper grim))))))

(defun hyprland-preview--cancel-active-process ()
  "Cancel the currently active capture process, if any."
  (when (process-live-p hyprland-preview--active-process)
    (delete-process hyprland-preview--active-process))
  (setq hyprland-preview--active-process nil)
  (hyprland-preview--restore-focus))

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
              (attempts (hyprland-preview--capture-attempts window)))
          (if (null attempts)
              (funcall callback
                       (list :ok nil
                             :reason 'no-capture-backend
                             :message "No available preview backend (helper/grim)"))
            (cl-labels
                ((run-attempt (remaining)
                   (let* ((attempt (car remaining))
                          (backend (plist-get attempt :backend))
                          (program (plist-get attempt :program))
                          (args (plist-get attempt :args))
                          (chunks nil))
                     (when (eq backend 'grim)
                       (hyprland-preview--prepare-focus-for-capture window))
                     (setq hyprland-preview--active-process
                           (make-process
                            :name (format "hyprland-preview-%s" backend)
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
                                (when (eq backend 'grim)
                                  (hyprland-preview--restore-focus))
                                (if (and (eq (process-status process) 'exit)
                                         (= (process-exit-status process) 0))
                                    (let ((bytes (apply #'concat (nreverse chunks))))
                                      (hyprland-preview--cache-put key bytes)
                                      (funcall callback (list :ok t :png-bytes bytes :cached nil)))
                                  (if (cdr remaining)
                                      (run-attempt (cdr remaining))
                                    (funcall callback
                                             (list :ok nil
                                                   :reason 'capture-failed
                                                   :message
                                                   (format "%s backend exited %s"
                                                           backend
                                                           (if (eq (process-status process) 'exit)
                                                               (process-exit-status process)
                                                             (process-status process))))))))))))))
              (run-attempt attempts))))))))

(provide 'hyprland-preview)
;;; hyprland-preview.el ends here
