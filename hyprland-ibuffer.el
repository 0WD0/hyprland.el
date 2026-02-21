;;; hyprland-ibuffer.el --- Ibuffer bridge for Hyprland windows -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Mirrors Hyprland windows into regular Emacs buffers so users can manage them
;; with ibuffer workflows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ibuffer)
(require 'hyprland-sync)

(defgroup hyprland-ibuffer nil
  "Ibuffer integration for hyprland.el."
  :group 'hyprland)

(defvar hyprland-ibuffer--address->buffer (make-hash-table :test #'equal)
  "Map normalized window addresses to mirror buffers.")

(defvar-local hyprland-window-address nil)
(defvar-local hyprland-window-data nil)

(defvar-keymap hyprland-window-buffer-mode-map
  :doc "Keymap for `hyprland-window-buffer-mode'."
  "g" #'hyprland-buffer-jump
  "k" #'hyprland-buffer-close)

(define-derived-mode hyprland-window-buffer-mode special-mode "HyprWindow"
  "Major mode for mirrored Hyprland window buffers."
  (setq buffer-read-only t))

(defun hyprland-ibuffer--buffer-name (window)
  "Return mirror buffer name for WINDOW alist."
  (let ((title (or (alist-get 'title window) "<untitled>"))
        (class (or (alist-get 'class window) "?"))
        (addr (or (alist-get 'address window) "?")))
    (format "*hypr:%s (%s) <%s>*" title class addr)))

(defun hyprland-ibuffer--render-buffer (buffer window)
  "Render WINDOW metadata into BUFFER and update local state."
  (with-current-buffer buffer
    (unless (derived-mode-p 'hyprland-window-buffer-mode)
      (hyprland-window-buffer-mode))
    (setq hyprland-window-data window
          hyprland-window-address (hyprland--normalize-address (alist-get 'address window)))
    (let ((inhibit-read-only t)
          (ws (alist-get 'workspace window)))
      (erase-buffer)
      (insert (format "Title: %s\n" (or (alist-get 'title window) "")))
      (insert (format "Class: %s\n" (or (alist-get 'class window) "")))
      (insert (format "Address: %s\n" hyprland-window-address))
      (insert (format "Workspace: %s\n"
                      (cond
                       ((and (listp ws) (alist-get 'name ws)) (alist-get 'name ws))
                       ((and (listp ws) (alist-get 'id ws)) (alist-get 'id ws))
                       (t "?"))))
      (insert (format "PID: %s\n" (or (alist-get 'pid window) "")))
      (goto-char (point-min)))))

(defun hyprland-ibuffer-sync-buffers ()
  "Sync mirror buffers from current `hyprland-windows' state."
  (interactive)
  (let ((alive (make-hash-table :test #'equal)))
    (dolist (window (hyprland-windows))
      (let* ((address (hyprland--normalize-address (alist-get 'address window)))
             (buffer (or (gethash address hyprland-ibuffer--address->buffer)
                         (generate-new-buffer (hyprland-ibuffer--buffer-name window)))))
        (puthash address t alive)
        (puthash address buffer hyprland-ibuffer--address->buffer)
        (with-current-buffer buffer
          (rename-buffer (hyprland-ibuffer--buffer-name window) t))
        (hyprland-ibuffer--render-buffer buffer window)))
    (let (stale)
      (maphash
       (lambda (address buffer)
         (unless (gethash address alive)
           (push (cons address buffer) stale)))
       hyprland-ibuffer--address->buffer)
      (dolist (it stale)
        (remhash (car it) hyprland-ibuffer--address->buffer)
        (when (buffer-live-p (cdr it))
          (kill-buffer (cdr it)))))))

(defun hyprland-buffer-jump ()
  "Focus Hyprland window represented by current buffer."
  (interactive)
  (unless hyprland-window-address
    (user-error "Current buffer is not a Hyprland mirror buffer"))
  (hyprland-jump hyprland-window-address))

(defun hyprland-buffer-close ()
  "Close Hyprland window represented by current buffer."
  (interactive)
  (unless hyprland-window-address
    (user-error "Current buffer is not a Hyprland mirror buffer"))
  (hyprland-close hyprland-window-address))

(defun hyprland-buffer-tag (tag-op)
  "Apply TAG-OP to Hyprland window represented by current buffer."
  (interactive "sTag op (+foo/-foo/foo): ")
  (unless hyprland-window-address
    (user-error "Current buffer is not a Hyprland mirror buffer"))
  (hyprland-tag hyprland-window-address tag-op))

(defun hyprland-ibuffer-open ()
  "Open ibuffer filtered to Hyprland mirror buffers."
  (interactive)
  (ibuffer nil "*Ibuffer-hyprland*")
  (when-let* ((buf (get-buffer "*Ibuffer-hyprland*")))
    (with-current-buffer buf
      (ibuffer-filter-disable)
      (ibuffer-filter-by-derived-mode 'hyprland-window-buffer-mode))))

(define-minor-mode hyprland-ibuffer-mirror-mode
  "Mirror Hyprland windows into regular Emacs buffers for ibuffer workflows."
  :global t
  :group 'hyprland-ibuffer
  (if hyprland-ibuffer-mirror-mode
      (progn
        (add-hook 'hyprland-after-refresh-hook #'hyprland-ibuffer-sync-buffers)
        (ignore-errors (hyprland-ibuffer-sync-buffers)))
    (remove-hook 'hyprland-after-refresh-hook #'hyprland-ibuffer-sync-buffers)))

(provide 'hyprland-ibuffer)
;;; hyprland-ibuffer.el ends here
