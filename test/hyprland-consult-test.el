;;; hyprland-consult-test.el --- Tests for consult integration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-consult)

(ert-deftest hyprland-consult-test-state/accepts-direct-action-cand-callback ()
  (should-not (hyprland-consult--state 'setup nil))
  (should-not (hyprland-consult--state 'return nil)))

(ert-deftest hyprland-consult-test-state/preview-nil-cleans-up ()
  (let (called)
    (cl-letf (((symbol-function 'hyprland-consult--cleanup-preview)
               (lambda () (setq called t))))
      (hyprland-consult--state 'preview nil)
      (should called))))

(ert-deftest hyprland-consult-test-state/preview-candidate-triggers-preview-request ()
  (let* ((window '((address . "0xabc")))
         (candidate (propertize "x" 'hyprland-window window))
         seen-window)
    (cl-letf (((symbol-function 'hyprland-preview-request)
               (lambda (w _cb) (setq seen-window w))))
      (hyprland-consult--state 'preview candidate)
      (should (equal seen-window window)))))

(provide 'hyprland-consult-test)
;;; hyprland-consult-test.el ends here
