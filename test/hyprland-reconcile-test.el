;;; hyprland-reconcile-test.el --- Tests for reconcile policy -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-reconcile)

(ert-deftest hyprland-reconcile-test-prefer-mode ()
  (should (eq (hyprland-reconcile--prefer-mode 'fast 'full) 'full))
  (should (eq (hyprland-reconcile--prefer-mode nil 'fast) 'fast))
  (should-not (hyprland-reconcile--prefer-mode nil nil)))

(ert-deftest hyprland-reconcile-test-run-promotes-fast-to-full-when-not-allowed ()
  (let (mode)
    (cl-letf (((symbol-function 'hyprland-reconcile--fast-allowed-p)
               (lambda () nil))
              (hyprland-reconcile-function
               (lambda (m) (setq mode m))))
      (hyprland-reconcile--run 'fast)
      (should (eq mode 'full)))))

(ert-deftest hyprland-reconcile-test-run-notes-fast-accounting ()
  (let (called)
    (cl-letf (((symbol-function 'hyprland-reconcile--fast-allowed-p)
               (lambda () t))
              ((symbol-function 'hyprland-reconcile--note-fast-run)
               (lambda () (setq called t)))
              (hyprland-reconcile-function
               (lambda (_m) nil)))
      (hyprland-reconcile--run 'fast)
      (should called))))

(ert-deftest hyprland-reconcile-test-request-uses-one-shot-debounce-timer ()
  (let (scheduled)
    (setq hyprland-reconcile--debounce-timer nil
          hyprland-reconcile--pending-mode nil)
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (secs repeat fn &rest args)
                 (setq scheduled (list secs repeat fn args))
                 'fake-timer)))
      (hyprland-reconcile-request-fast "test")
      (should (equal (nth 1 scheduled) nil))
      (should (eq (nth 2 scheduled) #'hyprland-reconcile--flush-debounced))
      (should (eq hyprland-reconcile--debounce-timer 'fake-timer)))))

(ert-deftest hyprland-reconcile-test-stop-cancels-flush-function-timers ()
  (let (cancelled)
    (cl-letf (((symbol-function 'cancel-function-timers)
               (lambda (fn)
                 (setq cancelled fn))))
      (hyprland-reconcile-stop)
      (should (eq cancelled #'hyprland-reconcile--flush-debounced)))))

(provide 'hyprland-reconcile-test)
;;; hyprland-reconcile-test.el ends here
