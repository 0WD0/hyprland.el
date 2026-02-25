;;; hyprland-preview-ui.el --- Shared preview display helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared preview rendering/display lifecycle used by multiple frontends.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar hyprland-preview-ui--buffer-name " *hyprland-preview*"
  "Preview buffer name shared across UI integrations.")

(defvar hyprland-preview-ui--window nil
  "Window currently used to render preview in current-window mode.")

(defvar hyprland-preview-ui--restore nil
  "Saved `(buffer start point)' tuple for restoring current-window preview.")

(defvar hyprland-preview-ui--failed-image-fingerprints (make-hash-table :test #'equal)
  "Cache of payload fingerprints that previously failed to render.")

(defvar hyprland-preview-ui-preview-context-functions nil
  "List of zero-arg predicates returning non-nil for preview context.")

(defun hyprland-preview-ui-preview-context-p ()
  "Return non-nil when any registered preview context predicate is active."
  (cl-some (lambda (fn)
             (ignore-errors
               (funcall fn)))
           hyprland-preview-ui-preview-context-functions))

(defun hyprland-preview-ui--bytes-prefix-p (bytes prefix)
  "Return non-nil when BYTES starts with PREFIX integer list."
  (and (stringp bytes)
       (>= (length bytes) (length prefix))
       (cl-loop for b in prefix
                for i from 0
                always (= (aref bytes i) b))))

(defun hyprland-preview-ui--valid-image-bytes-p (bytes image-type)
  "Return non-nil when BYTES header matches IMAGE-TYPE magic."
  (pcase image-type
    ('png (hyprland-preview-ui--bytes-prefix-p bytes '(137 80 78 71 13 10 26 10)))
    ('jpeg (hyprland-preview-ui--bytes-prefix-p bytes '(255 216 255)))
    (_ nil)))

(defun hyprland-preview-ui--image-fingerprint (bytes image-type)
  "Build stable fingerprint string for BYTES and IMAGE-TYPE."
  (when (and (stringp bytes) (symbolp image-type))
    (format "%s:%s" image-type (secure-hash 'sha1 bytes))))

(defun hyprland-preview-ui--render-preview-buffer (buffer payload)
  "Render PAYLOAD into preview BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (setq buffer-read-only nil)
      (goto-char (point-min))
      (erase-buffer)
      (pcase (plist-get payload :ok)
        ('t
         (let* ((bytes (or (plist-get payload :image-bytes)
                           (plist-get payload :png-bytes)))
                (image-type (or (plist-get payload :image-type) 'png))
                (explicit-image (plist-member payload :image-bytes))
                (fingerprint (hyprland-preview-ui--image-fingerprint bytes image-type)))
           (condition-case err
               (if (and bytes
                        (display-images-p)
                        (image-type-available-p image-type)
                        (or explicit-image
                            (hyprland-preview-ui--valid-image-bytes-p bytes image-type))
                        (not (and fingerprint
                                  (gethash fingerprint hyprland-preview-ui--failed-image-fingerprints))))
                   (progn
                     (set-buffer-multibyte nil)
                     (insert-image (create-image bytes image-type t :scale 0.45))
                     (insert "\n"))
                 (insert "Preview image unavailable in current Emacs display\n"))
             (error
              (when fingerprint
                (puthash fingerprint t hyprland-preview-ui--failed-image-fingerprints))
              (insert (format "Preview render error: %s\n" (error-message-string err)))))))
        (_
         (insert (or (plist-get payload :message) "Preview unavailable") "\n")))
      (setq buffer-read-only t))
    (image-mode)))

(defun hyprland-preview-ui--base-window ()
  "Return target window used for in-place preview."
  (or (when-let* ((win (and (fboundp 'consult--original-window)
                            (consult--original-window))))
        (and (window-live-p win)
             (not (window-minibuffer-p win))
             win))
      (when-let* ((win (minibuffer-selected-window)))
        (and (window-live-p win)
             (not (window-minibuffer-p win))
             win))
      (let ((win (selected-window)))
        (and (window-live-p win)
             (not (window-minibuffer-p win))
             win))))

(defun hyprland-preview-ui--display-side-window (buffer)
  "Display preview BUFFER in a dedicated side window."
  (display-buffer-in-side-window
   buffer
   '((side . right) (slot . 1) (window-width . 0.33))))

(defun hyprland-preview-ui--display-current-window (buffer)
  "Display preview BUFFER in the original completion window."
  (when-let* ((win (or (and (window-live-p hyprland-preview-ui--window)
                            hyprland-preview-ui--window)
                       (hyprland-preview-ui--base-window))))
    (unless (and (window-live-p hyprland-preview-ui--window)
                 hyprland-preview-ui--restore)
      (setq hyprland-preview-ui--window win
            hyprland-preview-ui--restore
            (list (window-buffer win)
                  (window-start win)
                  (window-point win))))
    (condition-case nil
        (progn
          (set-window-buffer win buffer)
          (set-window-point win (point-min))
          win)
      (error nil))))

(defun hyprland-preview-ui-display (payload &optional display-policy)
  "Display preview PAYLOAD using DISPLAY-POLICY.

DISPLAY-POLICY accepts `current-window' (default) or `side-window'."
  (let* ((policy (or display-policy 'current-window))
         (buffer (get-buffer-create hyprland-preview-ui--buffer-name)))
    (hyprland-preview-ui--render-preview-buffer buffer payload)
    (or (and (eq policy 'current-window)
             (hyprland-preview-ui--display-current-window buffer))
        (hyprland-preview-ui--display-side-window buffer))))

(defun hyprland-preview-ui-cleanup ()
  "Close preview UI and restore previous window state."
  (when-let* ((buf (get-buffer hyprland-preview-ui--buffer-name)))
    (when (and (window-live-p hyprland-preview-ui--window)
               hyprland-preview-ui--restore)
      (pcase-let ((`(,orig ,start ,point) hyprland-preview-ui--restore))
        (when (buffer-live-p orig)
          (condition-case nil
              (progn
                (set-window-buffer hyprland-preview-ui--window orig)
                (set-window-start hyprland-preview-ui--window start t)
                (set-window-point hyprland-preview-ui--window point))
            (error nil)))))
    (dolist (win (get-buffer-window-list buf nil t))
      (when (window-live-p win)
        (quit-window nil win)))
    (setq hyprland-preview-ui--window nil
          hyprland-preview-ui--restore nil)
    (clrhash hyprland-preview-ui--failed-image-fingerprints)
    (kill-buffer buf)))

(provide 'hyprland-preview-ui)
;;; hyprland-preview-ui.el ends here
