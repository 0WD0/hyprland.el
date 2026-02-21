;;; hyprland-consult-test.el --- Tests for consult integration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-consult)

(ert-deftest hyprland-consult-test-state/accepts-direct-action-cand-callback ()
  (should-not (hyprland-consult--state 'setup nil))
  (should-not (hyprland-consult--state 'return nil)))

(ert-deftest hyprland-consult-test-state/return-always-cleans-up ()
  (let (called)
    (cl-letf (((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq called t)))
              ((symbol-function 'hyprland-preview-cancel)
               #'ignore))
      (hyprland-consult--state 'return "cand")
      (should called))))

(ert-deftest hyprland-consult-test-state/preview-nil-keeps-existing-preview ()
  (let (called)
    (cl-letf (((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq called t))))
      (hyprland-consult--state 'preview nil)
      (should-not called))))

(ert-deftest hyprland-consult-test-state/preview-candidate-triggers-preview-request ()
  (let* ((window '((address . "0xabc")))
         (candidate (propertize "x" 'hyprland-window window))
         seen-window)
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (_secs _repeat fn &rest args)
                 (apply fn args)
                 'fake-timer))
              ((symbol-function 'cancel-timer) #'ignore)
              ((symbol-function 'hyprland-preview-request)
               (lambda (w _cb) (setq seen-window w))))
      (hyprland-consult--state 'setup nil)
      (hyprland-consult--state 'preview candidate)
      (should (equal seen-window window)))))

(ert-deftest hyprland-consult-test-state/preview-same-candidate-deduped ()
  (let* ((window '((address . "0xabc")))
         (candidate (propertize "x" 'hyprland-window window))
         (calls 0))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (_secs _repeat fn &rest args)
                 (apply fn args)
                 'fake-timer))
              ((symbol-function 'cancel-timer) #'ignore)
              ((symbol-function 'hyprland-preview-request)
               (lambda (_w _cb) (cl-incf calls))))
      (hyprland-consult--state 'setup nil)
      (hyprland-consult--state 'preview candidate)
      (hyprland-consult--state 'preview candidate)
      (should (= calls 1)))))

(ert-deftest hyprland-consult-test-state/exit-cancels-preview-pipeline ()
  (let (cancelled cleaned)
    (cl-letf (((symbol-function 'hyprland-preview-cancel)
               (lambda () (setq cancelled t)))
              ((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq cleaned t))))
      (hyprland-consult--state 'exit nil)
      (should cancelled)
      (should cleaned))))

(ert-deftest hyprland-consult-test-window-from-candidate/fallback-table ()
  (let ((hyprland-consult--candidate-table (make-hash-table :test #'equal))
        (window '((address . "0xabc"))))
    (puthash "label" window hyprland-consult--candidate-table)
    (should (equal (hyprland-consult--window-from-candidate "label") window))))

(provide 'hyprland-consult-test)
;;; hyprland-consult-test.el ends here
