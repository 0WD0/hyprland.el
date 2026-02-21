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

(declare-function ibuffer-switch-to-saved-filter-groups "ibuf-ext" (name))
(defvar ibuffer-saved-filter-groups)

(defgroup hyprland-ibuffer nil
  "Ibuffer integration for hyprland.el."
  :group 'hyprland)

(defcustom hyprland-ibuffer-filter-group-name "Hyprland"
  "Name of the ibuffer filter group used for mirrored Hyprland buffers."
  :type 'string
  :group 'hyprland-ibuffer)

(defcustom hyprland-ibuffer-filter-group-position 'prepend
  "Where to insert the Hyprland filter group in `ibuffer-filter-groups'."
  :type '(choice (const :tag "At beginning" prepend)
          (const :tag "At end" append))
  :group 'hyprland-ibuffer)

(defcustom hyprland-ibuffer-saved-filter-group-profile "hyprland"
  "Name of `ibuffer-saved-filter-groups' profile managed by Hyprland helpers.

This profile is used by `hyprland-ibuffer-open-native'."
  :type 'string
  :group 'hyprland-ibuffer)

(defcustom hyprland-ibuffer-intercept-buffer-open t
  "When non-nil, opening mirror buffers jumps to the real Hyprland window.

This applies to interactive `switch-to-buffer' and `pop-to-buffer' while
`hyprland-ibuffer-mirror-mode' is enabled."
  :type 'boolean
  :group 'hyprland-ibuffer)

(defvar hyprland-ibuffer--address->buffer (make-hash-table :test #'equal)
  "Map normalized window addresses to mirror buffers.")

(defvar hyprland-ibuffer--suppress-kill-action nil
  "When non-nil, mirror-buffer kill should not dispatch window close.")

(defvar-local hyprland-window-address nil)
(defvar-local hyprland-window-data nil)
(defvar-local hyprland-window-title nil)
(defvar-local hyprland-window-class nil)
(defvar-local hyprland-window-workspace nil)
(defvar-local hyprland-window-pid nil)

(define-ibuffer-column hypr-ws
  (:name "WS")
  (or hyprland-window-workspace ""))

(define-ibuffer-column hypr-class
  (:name "Class")
  (or hyprland-window-class ""))

(define-ibuffer-column hypr-title
  (:name "Title")
  (or hyprland-window-title ""))

(define-ibuffer-column hypr-address
  (:name "Address")
  (or hyprland-window-address ""))

(define-ibuffer-column hypr-pid
  (:name "PID")
  (if hyprland-window-pid
      (format "%s" hyprland-window-pid)
    ""))

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
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'hyprland-ibuffer--on-mirror-buffer-kill nil t))

(defun hyprland-ibuffer--buffer-name (window)
  "Return mirror buffer name for WINDOW alist."
  (let ((title (or (alist-get 'title window) "<untitled>"))
        (class (or (alist-get 'class window) "?"))
        (addr (or (alist-get 'address window) "?")))
    (format "*hypr:%s (%s) <%s>*" title class addr)))

(defun hyprland-ibuffer--workspace-string (window)
  "Return workspace display string for WINDOW alist."
  (let ((ws (alist-get 'workspace window)))
    (cond
     ((and (listp ws) (alist-get 'name ws)) (format "%s" (alist-get 'name ws)))
     ((and (listp ws) (alist-get 'id ws)) (format "%s" (alist-get 'id ws)))
     (t "?"))))

(defun hyprland-ibuffer--filter-group-spec ()
  "Return ibuffer filter group definition for Hyprland mirror buffers."
  (list hyprland-ibuffer-filter-group-name
        '(mode . hyprland-window-buffer-mode)))

(defun hyprland-ibuffer--insert-group (groups)
  "Insert Hyprland group into GROUPS according to position preference."
  (if (eq hyprland-ibuffer-filter-group-position 'append)
      (append groups (list (hyprland-ibuffer--filter-group-spec)))
    (cons (hyprland-ibuffer--filter-group-spec) groups)))

(defun hyprland-ibuffer--prune-dead-index ()
  "Remove dead buffer entries from `hyprland-ibuffer--address->buffer'."
  (let (dead)
    (maphash
     (lambda (address buffer)
       (unless (buffer-live-p buffer)
         (push address dead)))
     hyprland-ibuffer--address->buffer)
    (dolist (address dead)
      (remhash address hyprland-ibuffer--address->buffer))))

(defun hyprland-ibuffer--resolve-buffer (buffer-or-name)
  "Resolve BUFFER-OR-NAME to a live buffer object or nil."
  (let ((buf (cond
              ((bufferp buffer-or-name) buffer-or-name)
              ((stringp buffer-or-name) (get-buffer buffer-or-name))
              (t nil))))
    (and (buffer-live-p buf) buf)))

(defun hyprland-ibuffer--maybe-jump-for-buffer (buffer)
  "Jump to Hyprland window represented by BUFFER and return non-nil if handled."
  (when-let* ((address (hyprland-ibuffer--buffer-address buffer)))
    (hyprland-jump address)
    t))

(defun hyprland-ibuffer--advice-switch-to-buffer (orig buffer-or-name &rest args)
  "Redirect interactive `switch-to-buffer' when BUFFER-OR-NAME is mirror buffer."
  (let ((buf (hyprland-ibuffer--resolve-buffer buffer-or-name)))
    (if (and hyprland-ibuffer-intercept-buffer-open
             (called-interactively-p 'interactive)
             buf
             (hyprland-ibuffer--maybe-jump-for-buffer buf))
        (current-buffer)
      (apply orig buffer-or-name args))))

(defun hyprland-ibuffer--advice-pop-to-buffer (orig buffer-or-name &rest args)
  "Redirect interactive `pop-to-buffer' when BUFFER-OR-NAME is mirror buffer."
  (let ((buf (hyprland-ibuffer--resolve-buffer buffer-or-name)))
    (if (and hyprland-ibuffer-intercept-buffer-open
             (called-interactively-p 'interactive)
             buf
             (hyprland-ibuffer--maybe-jump-for-buffer buf))
        (selected-window)
      (apply orig buffer-or-name args))))

(defun hyprland-ibuffer--on-mirror-buffer-kill ()
  "Synchronize mirror buffer kill with Hyprland window lifecycle."
  (when hyprland-window-address
    (remhash hyprland-window-address hyprland-ibuffer--address->buffer)
    (unless hyprland-ibuffer--suppress-kill-action
      (ignore-errors
        (hyprland-close hyprland-window-address)))))

(defun hyprland-ibuffer-install-saved-filter-group (&optional quiet)
  "Install Hyprland group into `ibuffer-saved-filter-groups' profile.

This uses native ibuffer saved-group mechanisms from `ibuf-ext'.
When QUIET is non-nil, suppress user-facing message output."
  (interactive)
  (require 'ibuf-ext)
  (unless (boundp 'ibuffer-saved-filter-groups)
    (setq ibuffer-saved-filter-groups nil))
  (let* ((profile hyprland-ibuffer-saved-filter-group-profile)
         (entry (assoc profile ibuffer-saved-filter-groups))
         (groups (if entry (copy-tree (cdr entry)) nil))
         (groups (assoc-delete-all hyprland-ibuffer-filter-group-name groups))
         (groups (hyprland-ibuffer--insert-group groups)))
    (if entry
        (setcdr entry groups)
      (push (cons profile groups) ibuffer-saved-filter-groups))
    (unless quiet
      (message "Installed Hyprland ibuffer saved filter profile: %s" profile))))

(defun hyprland-ibuffer--dead-index-count ()
  "Return number of dead-buffer entries in mirror index."
  (let ((count 0))
    (maphash
     (lambda (_address buffer)
       (unless (buffer-live-p buffer)
         (cl-incf count)))
     hyprland-ibuffer--address->buffer)
    count))

(defun hyprland-ibuffer-doctor ()
  "Repair and report Hyprland ibuffer integration health.

Doctor performs lightweight self-healing:
- prune dead mirror index entries;
- reinstall native saved filter-group profile.

Return a plist with diagnostics for scripting." 
  (interactive)
  (let* ((dead-before (hyprland-ibuffer--dead-index-count))
         (_ (hyprland-ibuffer--prune-dead-index))
         (dead-after (hyprland-ibuffer--dead-index-count))
         (pruned (- dead-before dead-after))
         (profile hyprland-ibuffer-saved-filter-group-profile)
         (_ (hyprland-ibuffer-install-saved-filter-group t))
         (report (list :dead-before dead-before
                       :dead-after dead-after
                       :pruned pruned
                       :profile profile
                       :group hyprland-ibuffer-filter-group-name)))
    (when (called-interactively-p 'interactive)
      (message "Hyprland ibuffer doctor: pruned=%d profile=%s group=%s"
               pruned profile hyprland-ibuffer-filter-group-name))
    report))


(defun hyprland-ibuffer--render-buffer (buffer window)
  "Render WINDOW metadata into BUFFER and update local state."
  (with-current-buffer buffer
    (unless (derived-mode-p 'hyprland-window-buffer-mode)
      (hyprland-window-buffer-mode))
    (setq hyprland-window-data window
          hyprland-window-address (hyprland--normalize-address (alist-get 'address window))
          hyprland-window-title (or (alist-get 'title window) "")
          hyprland-window-class (or (alist-get 'class window) "")
          hyprland-window-workspace (hyprland-ibuffer--workspace-string window)
          hyprland-window-pid (alist-get 'pid window))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Title: %s\n" hyprland-window-title))
      (insert (format "Class: %s\n" hyprland-window-class))
      (insert (format "Address: %s\n" hyprland-window-address))
      (insert (format "Workspace: %s\n" hyprland-window-workspace))
      (insert (format "PID: %s\n" (or hyprland-window-pid "")))
      (goto-char (point-min)))))

(defun hyprland-ibuffer--apply-formats ()
  "Apply Hyprland-focused ibuffer columns to current ibuffer buffer."
  (setq-local
   ibuffer-formats
   '((mark modified read-only locked
      " " (name 20 20 :left :elide)
      " " (hypr-ws 6 6 :left)
      " " (hypr-class 12 12 :left :elide)
      " " (hypr-title 28 28 :left :elide)
      " " (hypr-address 16 16 :left)
      " " (hypr-pid 7 7 :right)))))

(defun hyprland-ibuffer-sync-buffers ()
  "Sync mirror buffers from current `hyprland-windows' state."
  (interactive)
  (hyprland-ibuffer--prune-dead-index)
  (let ((alive (make-hash-table :test #'equal)))
    (dolist (window (hyprland-windows))
      (let* ((address (hyprland--normalize-address (alist-get 'address window)))
             (existing (gethash address hyprland-ibuffer--address->buffer))
             (buffer (or (and (buffer-live-p existing) existing)
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
          (let ((hyprland-ibuffer--suppress-kill-action t))
            (kill-buffer (cdr it))))))))

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
  "Open ibuffer using native saved filter-group profile for Hyprland.

This command relies on `ibuffer-saved-filter-groups' and
`ibuffer-switch-to-saved-filter-groups' from `ibuf-ext'."
  (interactive)
  (require 'ibuf-ext)
  (hyprland-ibuffer-install-saved-filter-group t)
  (ibuffer nil "*Ibuffer-hyprland*")
  (when-let* ((buf (get-buffer "*Ibuffer-hyprland*")))
    (with-current-buffer buf
      (ibuffer-switch-to-saved-filter-groups
       hyprland-ibuffer-saved-filter-group-profile)
      (hyprland-ibuffer--apply-formats)
      (hyprland-ibuffer-view-mode 1)
      (ibuffer-update nil t))))

(defun hyprland-ibuffer-open-native ()
  "Backward-compatible alias for `hyprland-ibuffer-open'."
  (interactive)
  (hyprland-ibuffer-open))

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
        (unless (advice-member-p #'hyprland-ibuffer--advice-switch-to-buffer 'switch-to-buffer)
          (advice-add 'switch-to-buffer :around #'hyprland-ibuffer--advice-switch-to-buffer))
        (unless (advice-member-p #'hyprland-ibuffer--advice-pop-to-buffer 'pop-to-buffer)
          (advice-add 'pop-to-buffer :around #'hyprland-ibuffer--advice-pop-to-buffer))
        (ignore-errors (hyprland-ibuffer-sync-buffers)))
    (remove-hook 'hyprland-after-refresh-hook #'hyprland-ibuffer-sync-buffers)
    (advice-remove 'switch-to-buffer #'hyprland-ibuffer--advice-switch-to-buffer)
    (advice-remove 'pop-to-buffer #'hyprland-ibuffer--advice-pop-to-buffer)))

(provide 'hyprland-ibuffer)
;;; hyprland-ibuffer.el ends here
