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
(defvar hyprland-consult--preview-window nil)
(defvar hyprland-consult--preview-restore nil)

(defcustom hyprland-consult-preview-key '(:debounce 0.12 any)
  "Preview trigger configuration passed to `consult--read'.

Examples:

- `any': preview on every candidate change.
- `(:debounce 0.3 any)': delayed auto preview.
- \"M-.\": manual preview trigger.
- nil: disable live preview."
  :type 'sexp
  :group 'hyprland)

(defcustom hyprland-consult-preview-display 'current-window
  "Where to display preview image during candidate navigation.

- `current-window': reuse the original window (Consult-style preview).
- `side-window': render preview in a right side window."
  :type '(choice (const :tag "Current window" current-window)
          (const :tag "Right side window" side-window))
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

(defun hyprland-consult--render-preview-buffer (buffer payload)
  "Render PAYLOAD into preview BUFFER."
  (with-current-buffer buffer
    (setq buffer-read-only nil)
    (erase-buffer)
    (pcase (plist-get payload :ok)
      ('t
       (let* ((bytes (or (plist-get payload :image-bytes)
                         (plist-get payload :png-bytes)))
              (image-type (or (plist-get payload :image-type) 'png)))
         (condition-case err
             (if (and bytes
                      (display-images-p)
                      (image-type-available-p image-type))
                 (progn
                   (set-buffer-multibyte nil)
                   (insert-image (create-image bytes image-type t :scale 0.45))
                   (insert "\n"))
               (insert "Preview image unavailable in current Emacs display\n"))
           (error
             (insert (format "Preview render error: %s\n" (error-message-string err)))))))
      (_
       (insert (or (plist-get payload :message) "Preview unavailable") "\n")))
    (setq buffer-read-only t)
    (image-mode)))

(defun hyprland-consult--preview-base-window ()
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

(defun hyprland-consult--display-preview-side-window (buffer)
  "Display preview BUFFER in a dedicated side window."
  (display-buffer-in-side-window
   buffer
   '((side . right) (slot . 1) (window-width . 0.33))))

(defun hyprland-consult--display-preview-current-window (buffer)
  "Display preview BUFFER in the original completion window."
  (when-let* ((win (or (and (window-live-p hyprland-consult--preview-window)
                            hyprland-consult--preview-window)
                       (hyprland-consult--preview-base-window))))
    (unless (and (window-live-p hyprland-consult--preview-window)
                 hyprland-consult--preview-restore)
      (setq hyprland-consult--preview-window win
            hyprland-consult--preview-restore
            (list (window-buffer win)
                  (window-start win)
                  (window-point win))))
    (condition-case nil
        (progn
          (set-window-buffer win buffer)
          (set-window-point win (point-min))
          win)
      (error nil))))

(defun hyprland-consult--display-preview (payload)
  "Display preview PAYLOAD using configured display policy."
  (let ((buffer (get-buffer-create hyprland-consult--preview-buffer-name)))
    (hyprland-consult--render-preview-buffer buffer payload)
    (or (and (eq hyprland-consult-preview-display 'current-window)
             (hyprland-consult--display-preview-current-window buffer))
        (hyprland-consult--display-preview-side-window buffer))))

(defun hyprland-consult--cleanup-preview ()
  "Close preview UI and restore previous window state."
  (when-let* ((buf (get-buffer hyprland-consult--preview-buffer-name)))
    (when (and (window-live-p hyprland-consult--preview-window)
               hyprland-consult--preview-restore)
      (pcase-let ((`(,orig ,start ,point) hyprland-consult--preview-restore))
        (when (buffer-live-p orig)
          (condition-case nil
              (progn
                (set-window-buffer hyprland-consult--preview-window orig)
                (set-window-start hyprland-consult--preview-window start t)
                (set-window-point hyprland-consult--preview-window point))
            (error nil)))))
    (dolist (win (get-buffer-window-list buf nil t))
      (when (window-live-p win)
        (quit-window nil win)))
    (setq hyprland-consult--preview-window nil
          hyprland-consult--preview-restore nil)
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
