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
(defvar hyprland-consult--candidate-table nil
  "Hash table from candidate label to Hyprland window object.")
(defvar hyprland-consult--preview-timer nil)
(defvar hyprland-consult--preview-token 0)
(defvar hyprland-consult--last-preview-label nil)

(defcustom hyprland-consult-preview-debounce-ms 120
  "Idle delay before firing a preview capture request."
  :type 'integer
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
  "Build completion candidates and a lookup table for window retrieval." 
  (setq hyprland-consult--candidate-table (make-hash-table :test #'equal))
  (mapcar
   (lambda (window)
     (let ((label (hyprland-consult--window-label window)))
       (puthash label window hyprland-consult--candidate-table)
       (propertize label 'hyprland-window window)))
   (hyprland-windows)))

(defun hyprland-consult--window-from-candidate (cand)
  "Resolve candidate CAND back to Hyprland window object.

Consult may strip text properties in some completion stacks, so this
function also falls back to hash-based label lookup."
  (or (and (stringp cand) (get-text-property 0 'hyprland-window cand))
      (and (stringp cand)
           hyprland-consult--candidate-table
           (gethash cand hyprland-consult--candidate-table))))

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

(defun hyprland-consult--cancel-preview-timer ()
  "Cancel pending preview debounce timer, if any."
  (when (timerp hyprland-consult--preview-timer)
    (cancel-timer hyprland-consult--preview-timer))
  (setq hyprland-consult--preview-timer nil))

(defun hyprland-consult--schedule-preview (cand)
  "Schedule debounced preview request for candidate CAND."
  (hyprland-consult--cancel-preview-timer)
  (let ((token hyprland-consult--preview-token))
    (setq hyprland-consult--preview-timer
          (run-with-timer
           (max 0.0 (/ (max 0 hyprland-consult-preview-debounce-ms) 1000.0))
           nil
           (lambda ()
             (setq hyprland-consult--preview-timer nil)
             (when (= token hyprland-consult--preview-token)
               (let ((label (and (stringp cand) (substring-no-properties cand))))
                 (unless (equal label hyprland-consult--last-preview-label)
                   (setq hyprland-consult--last-preview-label label)
                   (if-let* ((window (hyprland-consult--window-from-candidate cand)))
                       (hyprland-preview-request
                        window
                        (lambda (payload)
                          (when (= token hyprland-consult--preview-token)
                            (hyprland-consult--display-preview payload))))
                     (hyprland-consult--display-preview
                      (list :ok nil :message "Preview metadata missing for candidate")))))))))))

(defun hyprland-consult--reset-preview-state ()
  "Reset transient preview state for one Consult session."
  (hyprland-consult--cancel-preview-timer)
  (setq hyprland-consult--last-preview-label nil)
  (cl-incf hyprland-consult--preview-token))

(defun hyprland-consult--state (action cand)
  "Consult state callback for Hyprland preview.

ACTION and CAND follow Consult's :state contract.
This function intentionally handles the direct callback form
`(state action cand)'."
  (pcase action
    ('setup
     (hyprland-consult--reset-preview-state)
     nil)
    ('preview
     (when cand
       (hyprland-consult--schedule-preview cand)))
    ('exit
     (hyprland-consult--reset-preview-state)
     (hyprland-preview-cancel)
     (hyprland-consult--cleanup-preview))
    ('return
     (hyprland-consult--reset-preview-state)
     (hyprland-preview-cancel)
     (hyprland-consult--cleanup-preview))))

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
        (hyprland-consult--window-from-candidate choice)))
     (cands
      (let* ((choice (completing-read "Hypr window: " cands nil t))
             (idx (cl-position choice cands :test #'string=)))
        (when idx
          (hyprland-consult--window-from-candidate (nth idx cands)))))
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
