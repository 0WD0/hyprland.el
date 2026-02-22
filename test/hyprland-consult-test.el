;;; hyprland-consult-test.el --- Tests for consult integration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-consult)

(declare-function consult--lookup-cdr "consult" (selected candidates &rest _))

(ert-deftest hyprland-consult-test-state/accepts-direct-action-cand-callback ()
  (should-not (hyprland-consult--state 'setup nil))
  (should-not (hyprland-consult--state 'return nil)))

(ert-deftest hyprland-consult-test-state/return-always-cleans-up ()
  (let (called cancelled)
    (cl-letf (((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq called t)))
              ((symbol-function 'hyprland-preview-cancel)
               (lambda () (setq cancelled t))))
      (hyprland-consult--state 'return "cand")
      (should called)
      (should cancelled))))

(ert-deftest hyprland-consult-test-state/preview-nil-keeps-existing-preview ()
  (let (called requested)
    (cl-letf (((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq called t)))
              ((symbol-function 'hyprland-preview-request)
               (lambda (&rest _) (setq requested t))))
      (hyprland-consult--state 'preview nil)
      (should-not called)
      (should-not requested))))

(ert-deftest hyprland-consult-test-state/preview-window-triggers-preview-request ()
  (let* ((window '((address . "0xabc")))
         seen-window)
    (cl-letf (((symbol-function 'hyprland-consult--display-preview) #'ignore)
              ((symbol-function 'hyprland-preview-request)
               (lambda (w _cb) (setq seen-window w))))
      (hyprland-consult--state 'preview window)
      (should (equal seen-window window)))))

(ert-deftest hyprland-consult-test-display-preview/current-window-policy ()
  (let ((hyprland-consult-preview-display 'current-window)
        called-current
        called-side)
    (unwind-protect
        (cl-letf (((symbol-function 'hyprland-consult--render-preview-buffer)
                   #'ignore)
                  ((symbol-function 'hyprland-consult--display-preview-current-window)
                   (lambda (_buffer)
                     (setq called-current t)
                     'current))
                  ((symbol-function 'hyprland-consult--display-preview-side-window)
                   (lambda (_buffer)
                     (setq called-side t)
                     'side)))
          (should (eq (hyprland-consult--display-preview '(:ok t)) 'current))
          (should called-current)
          (should-not called-side))
      (when-let* ((buf (get-buffer hyprland-consult--preview-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest hyprland-consult-test-display-preview/current-window-fallback-to-side ()
  (let ((hyprland-consult-preview-display 'current-window)
        called-side)
    (unwind-protect
        (cl-letf (((symbol-function 'hyprland-consult--render-preview-buffer)
                   #'ignore)
                  ((symbol-function 'hyprland-consult--display-preview-current-window)
                   (lambda (_buffer) nil))
                  ((symbol-function 'hyprland-consult--display-preview-side-window)
                   (lambda (_buffer)
                     (setq called-side t)
                     'side)))
          (should (eq (hyprland-consult--display-preview '(:ok t)) 'side))
          (should called-side))
      (when-let* ((buf (get-buffer hyprland-consult--preview-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest hyprland-consult-test-render-preview-buffer/uses-generic-image-fields ()
  (let ((buf (get-buffer-create " *hyprland-preview-render*"))
        inserted-type)
    (unwind-protect
        (cl-letf (((symbol-function 'display-images-p)
                   (lambda () t))
                  ((symbol-function 'image-type-available-p)
                   (lambda (type) (eq type 'jpeg)))
                  ((symbol-function 'create-image)
                   (lambda (_bytes type _data-p &rest _props)
                     (setq inserted-type type)
                     :img))
                  ((symbol-function 'insert-image)
                   (lambda (_img)))
                  ((symbol-function 'image-mode)
                   #'ignore))
          (hyprland-consult--render-preview-buffer
           buf
           (list :ok t :image-bytes "x" :image-type 'jpeg))
          (should (eq inserted-type 'jpeg)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest hyprland-consult-test-render-preview-buffer/inhibits-read-only-text-properties ()
  (let ((buf (get-buffer-create " *hyprland-preview-render-ro*")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-images-p)
                   (lambda () nil))
                  ((symbol-function 'image-mode)
                   #'ignore))
          (with-current-buffer buf
            (erase-buffer)
            (insert "locked")
            (add-text-properties (point-min) (point-max) '(read-only t))
            (setq buffer-read-only t))
          (should
           (equal
            'ok
            (condition-case _err
                (progn
                  (hyprland-consult--render-preview-buffer
                   buf
                   (list :ok nil :message "updated"))
                  'ok)
              (text-read-only 'text-read-only)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest hyprland-consult-test-cleanup-preview/restores-current-window ()
  (let ((preview (get-buffer-create " *hyprland-preview*"))
        (origin (get-buffer-create " *hyprland-origin*"))
        (target (selected-window))
        start point)
    (unwind-protect
        (progn
          (set-window-buffer target origin)
          (setq start (window-start target)
                point (window-point target))
          (setq hyprland-consult--preview-window target
                hyprland-consult--preview-restore (list origin start point))
          (set-window-buffer target preview)
          (hyprland-consult--cleanup-preview)
          (should (eq (window-buffer target) origin))
          (should-not (buffer-live-p preview))
          (should-not hyprland-consult--preview-window)
          (should-not hyprland-consult--preview-restore))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(ert-deftest hyprland-consult-test-state/preview-invalid-candidate-shows-message ()
  (let (payload)
    (cl-letf (((symbol-function 'hyprland-consult--display-preview)
               (lambda (p) (setq payload p))))
      (hyprland-consult--state 'preview "label")
      (should payload)
      (should-not (plist-get payload :ok))
      (should (string-match-p "metadata missing" (plist-get payload :message))))))

(ert-deftest hyprland-consult-test-state/exit-cancels-preview-pipeline ()
  (let (cancelled cleaned)
    (cl-letf (((symbol-function 'hyprland-preview-cancel)
               (lambda () (setq cancelled t)))
              ((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq cleaned t))))
      (hyprland-consult--state 'exit nil)
      (should cancelled)
      (should cleaned))))

(ert-deftest hyprland-consult-test-select-window-candidate/consult-path ()
  (let* ((window '((address . "0xabc")))
         (cands (list (cons "x" window)))
         seen-args)
    (cl-letf (((symbol-function 'hyprland-consult--candidates)
               (lambda () cands))
              ((symbol-function 'consult--read)
               (lambda (table &rest args)
                 (setq seen-args (list table args))
                 window)))
      (should (equal (hyprland--select-window-candidate) window))
      (should (equal (car seen-args) cands))
      (should (eq (plist-get (cadr seen-args) :lookup) #'consult--lookup-cdr))
      (should (eq (plist-get (cadr seen-args) :state) #'hyprland-consult--state))
      (should (equal (plist-get (cadr seen-args) :preview-key)
                     hyprland-consult-preview-key)))))

(ert-deftest hyprland-consult-test-select-window-candidate/no-candidates ()
  (cl-letf (((symbol-function 'hyprland-consult--candidates)
             (lambda () nil))
            ((symbol-function 'consult--read)
             (lambda (&rest _args)
               (ert-fail "consult--read should not run for nil candidates"))))
    (should-not (hyprland--select-window-candidate))))

(provide 'hyprland-consult-test)
;;; hyprland-consult-test.el ends here
