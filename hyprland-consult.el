;;; hyprland-consult.el --- Consult integration for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Candidate UI and static screenshot preview for Hyprland windows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)
(require 'hyprland-sync)
(require 'hyprland-preview)

(declare-function consult--read "consult" (candidates &rest options))

(defvar hyprland-consult--preview-buffer-name " *hyprland-preview*")

(defun hyprland-consult--window-label (window)
  "Build candidate display label from WINDOW alist."
  (let* ((ws (alist-get 'workspace window))
         (ws-name (cond
                   ((and (listp ws) (alist-get 'name ws)) (alist-get 'name ws))
                   ((and (listp ws) (alist-get 'id ws)) (format "%s" (alist-get 'id ws)))
                   (t "?")))
         (title (or (alist-get 'title window) "<untitled>"))
         (class (or (alist-get 'class window) "?"))
         (addr (or (alist-get 'address window) "?")))
    (format "[%s] %s (%s) <%s>" ws-name title class addr)))

(defun hyprland-consult--candidates ()
  "Build completion candidates with embedded window objects." 
  (mapcar
   (lambda (window)
     (propertize (hyprland-consult--window-label window)
                 'hyprland-window window))
   (hyprland-windows)))

(defun hyprland-consult--display-preview (payload)
  "Display preview PAYLOAD in dedicated side window." 
  (let* ((buffer (get-buffer-create hyprland-consult--preview-buffer-name))
         (window (display-buffer-in-side-window
                  buffer
                  '((side . right) (slot . 1) (window-width . 0.33)))))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (pcase (plist-get payload :ok)
        ('t
         (let ((bytes (plist-get payload :png-bytes)))
           (set-buffer-multibyte nil)
           (insert-image (create-image bytes 'png t :scale 0.45))
           (insert "\n")))
        (_
         (insert (or (plist-get payload :message) "Preview unavailable") "\n")))
      (setq buffer-read-only t)
      (image-mode))
    window))

(defun hyprland-consult--cleanup-preview ()
  "Close and clear preview side window/buffer." 
  (when-let* ((buf (get-buffer hyprland-consult--preview-buffer-name)))
    (when-let* ((win (get-buffer-window buf t)))
      (quit-window nil win))
    (kill-buffer buf)))

(defun hyprland-consult--state ()
  "Consult state constructor for Hyprland preview.

Implements the setup/preview/exit/return lifecycle.
This intentionally follows Consult's private :state contract."
  (lambda (action cand)
    (pcase action
      ('setup nil)
      ('preview
       (if cand
           (let ((window (get-text-property 0 'hyprland-window cand)))
             (hyprland-preview-request
              window
              (lambda (payload)
                (hyprland-consult--display-preview payload))))
         (hyprland-consult--cleanup-preview)))
      ('exit
       (hyprland-consult--cleanup-preview))
      ('return
       (unless cand
         (hyprland-consult--cleanup-preview))))))

(defun hyprland--select-window-candidate ()
  "Select a window candidate using Consult when available.

Return selected window object, or nil." 
  (let ((cands (hyprland-consult--candidates)))
    (cond
     ((and (fboundp 'consult--read) cands)
      (let ((choice (consult--read cands
                                   :prompt "Hypr window: "
                                   :require-match t
                                   :state #'hyprland-consult--state)))
        (get-text-property 0 'hyprland-window choice)))
     (cands
      (let* ((choice (completing-read "Hypr window: " cands nil t))
             (idx (cl-position choice cands :test #'string=)))
        (when idx
          (get-text-property 0 'hyprland-window (nth idx cands)))))
     (t nil))))

(defun hyprland-window-switch ()
  "Pick a window and focus it, with preview support." 
  (interactive)
  (hyprland-refresh)
  (if-let* ((window (hyprland--select-window-candidate))
            (address (alist-get 'address window)))
      (hyprland-jump address)
    (user-error "No window selected")))

(provide 'hyprland-consult)
;;; hyprland-consult.el ends here
