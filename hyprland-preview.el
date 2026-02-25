;;; hyprland-preview.el --- Screenshot preview helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Async static preview capture via toplevel helper with single-flight semantics.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)

(defvar hyprland-preview--cache (make-hash-table :test #'equal))
(defvar hyprland-preview--cache-bytes 0)
(defvar hyprland-preview--active-process nil)
(defvar hyprland-preview--active-token 0)

(defcustom hyprland-preview-toplevel-helper-executable "hyprland-toplevel-snap"
  "Executable used for toplevel-export preview capture."
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

(defun hyprland-preview--toplevel-helper-path ()
  "Return absolute path of toplevel helper executable, or nil."
  (when (stringp hyprland-preview-toplevel-helper-executable)
    (let ((from-path (executable-find hyprland-preview-toplevel-helper-executable)))
      (or (and (hyprland-preview--usable-executable-p from-path) from-path)
          (let* ((lib (or load-file-name (locate-library "hyprland-preview")))
                 (root (and lib (file-name-directory lib)))
                 (local (and root (expand-file-name "tools/hyprland-toplevel-snap" root))))
            (when (hyprland-preview--usable-executable-p local)
              local))))))

(defun hyprland-preview--toplevel-capture-attempt (window)
  "Build toplevel helper capture attempt for WINDOW, or nil."
  (when-let* ((helper (hyprland-preview--toplevel-helper-path))
              (address (alist-get 'address window)))
    (list :program helper
          :args (append (when hyprland-preview-overlay-cursor (list "--cursor"))
                        (list "--address" (hyprland--normalize-address address))))))

(defun hyprland-preview--capture-command (window)
  "Build capture command plist for WINDOW, or nil when helper unavailable."
  (hyprland-preview--toplevel-capture-attempt window))

(defun hyprland-preview--cancel-active-process ()
  "Cancel the currently active capture process, if any."
  (when (process-live-p hyprland-preview--active-process)
    (delete-process hyprland-preview--active-process))
  (setq hyprland-preview--active-process nil))

(defun hyprland-preview-cancel ()
  "Cancel the active preview request and invalidate in-flight callbacks."
  (hyprland-preview--cancel-active-process)
  (cl-incf hyprland-preview--active-token))

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
              (attempt (hyprland-preview--capture-command window)))
          (if (null attempt)
              (funcall callback
                       (list :ok nil :reason 'capture-helper-unavailable :message "Preview helper unavailable"))
            (let* ((program (plist-get attempt :program))
                   (args (plist-get attempt :args))
                   (chunks nil)
                   (process
                    (condition-case err
                        (make-process
                         :name "hyprland-preview-toplevel"
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
                             (if (and (eq (process-status process) 'exit)
                                      (= (process-exit-status process) 0))
                                 (let ((bytes (apply #'concat (nreverse chunks))))
                                   (hyprland-preview--cache-put key bytes)
                                   (funcall callback (list :ok t :png-bytes bytes :cached nil)))
                               (funcall callback
                                        (list :ok nil
                                              :reason 'capture-failed
                                              :message
                                              (format "Preview helper exited %s"
                                                      (if (eq (process-status process) 'exit)
                                                          (process-exit-status process)
                                                        (process-status process)))))))))
                      (error
                       (setq hyprland-preview--active-process nil)
                       (funcall callback
                                (list :ok nil
                                      :reason 'capture-failed
                                      :message
                                      (format "Preview helper failed to start: %s"
                                              (error-message-string err))))
                       nil))))
              (when process
                (setq hyprland-preview--active-process process)))))))))

(provide 'hyprland-preview)
;;; hyprland-preview.el ends here
