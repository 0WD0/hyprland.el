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

(defvar hyprland-ibuffer-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap ibuffer-visit-buffer] #'hyprland-ibuffer-jump-at-point)
    (define-key map [remap ibuffer-visit-buffer-other-window] #'hyprland-ibuffer-jump-at-point)
    (define-key map [remap ibuffer-visit-buffer-other-window-noselect] #'hyprland-ibuffer-jump-at-point)
    (define-key map [remap ibuffer-visit-buffer-other-frame] #'hyprland-ibuffer-jump-at-point)
    (define-key map [remap ibuffer-visit-buffer-1-window] #'hyprland-ibuffer-jump-at-point)
    (define-key map [remap ibuffer-do-kill-lines] #'hyprland-ibuffer-close-marked-or-current)
    map)
  "Keymap for direct actions in Hyprland ibuffer view.")

(define-minor-mode hyprland-ibuffer-view-mode
  "Minor mode for direct Hyprland actions inside ibuffer."
  :lighter " HyprIbuf"
  :keymap hyprland-ibuffer-view-mode-map)

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
      (ibuffer-filter-by-derived-mode 'hyprland-window-buffer-mode)
      (hyprland-ibuffer-view-mode 1))))

(defun hyprland-ibuffer--mirror-buffer-at-point ()
  "Return Hyprland mirror buffer represented by current ibuffer row."
  (unless (derived-mode-p 'ibuffer-mode)
    (user-error "Not in ibuffer"))
  (let ((buffer (ibuffer-current-buffer t)))
    (unless (and (buffer-live-p buffer)
                 (buffer-local-value 'hyprland-window-address buffer))
      (user-error "Current row is not a Hyprland mirror buffer"))
    buffer))

(defun hyprland-ibuffer--buffer-address (buffer)
  "Return normalized window address represented by mirror BUFFER.

Return nil when BUFFER is not a Hyprland mirror buffer."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'hyprland-window-address buffer))
    (buffer-local-value 'hyprland-window-address buffer)))

(defun hyprland-ibuffer-jump-at-point ()
  "Jump to Hyprland window represented by current ibuffer row."
  (interactive)
  (let ((buffer (hyprland-ibuffer--mirror-buffer-at-point)))
    (with-current-buffer buffer
      (hyprland-buffer-jump))))

(defun hyprland-ibuffer-close-at-point ()
  "Close Hyprland window represented by current ibuffer row."
  (interactive)
  (let ((buffer (hyprland-ibuffer--mirror-buffer-at-point)))
    (with-current-buffer buffer
      (hyprland-buffer-close))))

(defun hyprland-ibuffer-close-marked-or-current ()
  "Close marked Hyprland windows in ibuffer, or close current row.

This remaps `ibuffer-do-kill-lines' (default key: `k') inside
Hyprland ibuffer view to preserve ibuffer muscle memory."
  (interactive)
  (unless (derived-mode-p 'ibuffer-mode)
    (user-error "Not in ibuffer"))
  (let* ((marked (ibuffer-get-marked-buffers))
         (targets (if marked
                      marked
                    (list (ibuffer-current-buffer t))))
         (count 0))
    (dolist (buf targets)
      (when-let* ((address (hyprland-ibuffer--buffer-address buf)))
        (hyprland-close address)
        (cl-incf count)))
    (if (> count 0)
        (message "Closed %d Hyprland window(s)" count)
      (user-error "No Hyprland windows in selection"))))

(defun hyprland-ibuffer-tag-at-point (tag-op)
  "Tag Hyprland window at current ibuffer row using TAG-OP."
  (interactive "sTag op (+foo/-foo/foo): ")
  (let ((buffer (hyprland-ibuffer--mirror-buffer-at-point)))
    (with-current-buffer buffer
      (hyprland-buffer-tag tag-op))))

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
