;;; hyprland-consult.el --- Consult integration for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Candidate UI and static screenshot preview for Hyprland windows.

;;; Code:

(require 'subr-x)
(require 'consult)
(require 'hyprland-base)
(require 'hyprland-sync)
(require 'hyprland-preview)
(require 'hyprland-preview-ui)

(defvar consult--preview-function)

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

(defun hyprland-consult--preview-context-p ()
  "Return non-nil when a Consult minibuffer preview loop is active."
  (when-let* ((mini (active-minibuffer-window)))
    (with-current-buffer (window-buffer mini)
      (and (boundp 'consult--preview-function)
           consult--preview-function))))

(unless (member #'hyprland-consult--preview-context-p
                hyprland-preview-ui-preview-context-functions)
  (setq hyprland-preview-ui-preview-context-functions
        (append hyprland-preview-ui-preview-context-functions
                (list #'hyprland-consult--preview-context-p))))

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
              (hyprland-preview-ui-display payload hyprland-consult-preview-display)))
         (hyprland-preview-ui-display
          (list :ok nil :message "Preview metadata missing for candidate")
          hyprland-consult-preview-display))))
    ((or 'exit 'return)
     (hyprland-preview-cancel)
     (hyprland-preview-ui-cleanup))))

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
