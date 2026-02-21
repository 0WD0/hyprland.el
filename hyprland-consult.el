;;; hyprland-consult.el --- Consult integration for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Candidate UI and static screenshot preview for Hyprland windows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'consult)
(require 'hyprland-base)
(require 'hyprland-sync)
(require 'hyprland-preview)

(defvar hyprland-consult--preview-buffer-name " *hyprland-preview*")

(defcustom hyprland-consult-preview-key '(:debounce 0.12 any)
  "Preview trigger configuration passed to `consult--read'.

Examples:

- `any': preview on every candidate change.
- `(:debounce 0.3 any)': delayed auto preview.
- \"M-.\": manual preview trigger.
- nil: disable live preview."
  :type 'sexp
  :group 'hyprland)

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
  "Build completion alist `(DISPLAY . WINDOW)' for selection.

In Consult mode, WINDOW is recovered via `consult--lookup-cdr', so preview and
return action both receive the same structured value."
  (mapcar (lambda (window)
            (cons (hyprland-consult--window-label window) window))
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
           (condition-case err
               (if (and (display-images-p)
                        (image-type-available-p 'png))
                   (progn
                     (set-buffer-multibyte nil)
                     (insert-image (create-image bytes 'png t :scale 0.45))
                     (insert "\n"))
                 (insert "Preview image unsupported in current Emacs display\n"))
             (error
              (insert (format "Preview render error: %s\n" (error-message-string err)))))))
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

(defun hyprland-consult--state (action cand)
  "Consult state callback for Hyprland preview.

ACTION and CAND follow Consult's :state contract.
When using `consult--lookup-cdr', CAND is a Hyprland window alist."
  (pcase action
    ('setup nil)
    ('preview
     (when cand
       (if (and (listp cand) (alist-get 'address cand))
           (hyprland-preview-request
            cand
            (lambda (payload)
              (hyprland-consult--display-preview payload)))
         (hyprland-consult--display-preview
          (list :ok nil :message "Preview metadata missing for candidate")))))
    ('exit
     (hyprland-preview-cancel)
     (hyprland-consult--cleanup-preview))
    ('return
     (hyprland-preview-cancel)
     (hyprland-consult--cleanup-preview))))

(defun hyprland--select-window-candidate ()
  "Select a window candidate via Consult and return window object, or nil."
  (when-let* ((cands (hyprland-consult--candidates)))
    (consult--read cands
                   :prompt "Hypr window: "
                   :require-match t
                   :sort nil
                   :lookup #'consult--lookup-cdr
                   :preview-key hyprland-consult-preview-key
                   :state #'hyprland-consult--state)))

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
