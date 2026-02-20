;;; hyprland-preview.el --- Screenshot preview helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Async static preview capture using grim with single-flight semantics.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)

(defvar hyprland-preview--grim-supports-target nil)
(defvar hyprland-preview--cache (make-hash-table :test #'equal))
(defvar hyprland-preview--active-process nil)
(defvar hyprland-preview--active-token 0)

(defcustom hyprland-preview-ttl-seconds 20
  "Maximum age of cached previews in seconds."
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

(defun hyprland-preview--capture-args (window)
  "Return command args for capturing WINDOW preview.

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

(defun hyprland-preview--cancel-active-process ()
  "Cancel the currently active capture process, if any."
  (when (process-live-p hyprland-preview--active-process)
    (delete-process hyprland-preview--active-process))
  (setq hyprland-preview--active-process nil))

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
              (args (condition-case err
                        (hyprland-preview--capture-args window)
                      (error
                       (funcall callback
                                (list :ok nil :reason 'no-capture-args :message (error-message-string err)))
                       nil))))
          (when args
            (let ((chunks nil))
              (setq hyprland-preview--active-process
                    (make-process
                     :name "hyprland-preview"
                     :command (cons hyprland-grim-executable args)
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
                                          (format "grim exited %s"
                                                  (if (eq (process-status process) 'exit)
                                                      (process-exit-status process)
                                                    (process-status process)))))))))))))))))

(provide 'hyprland-preview)
;;; hyprland-preview.el ends here
