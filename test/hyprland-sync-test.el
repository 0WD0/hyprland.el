;;; hyprland-sync-test.el --- Tests for hyprland sync -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-sync)

(ert-deftest hyprland-sync-test-split-event-line/valid ()
  (let ((ev (hyprland-sync--split-event-line "windowtitlev2>>abc123,Title")))
    (should (eq (plist-get ev :name) 'windowtitlev2))
    (should (equal (plist-get ev :payload) "abc123,Title"))))

(ert-deftest hyprland-sync-test-split-event-line/invalid ()
  (should-not (hyprland-sync--split-event-line "garbage")))

(ert-deftest hyprland-sync-test-process-event/close-removes-window ()
  (let ((hyprland-sync--windows (make-hash-table :test #'equal))
        fast-called)
    (puthash "0xabc123" '((address . "0xabc123")) hyprland-sync--windows)
    (cl-letf (((symbol-function 'hyprland-reconcile-request-fast)
               (lambda (&rest _) (setq fast-called t)))
              ((symbol-function 'hyprland-reconcile-request-full)
               (lambda (&rest _) nil)))
      (hyprland-sync--process-event (list :name 'closewindow :payload "abc123"))
      (should fast-called)
      (should-not (gethash "0xabc123" hyprland-sync--windows)))))

(ert-deftest hyprland-sync-test-process-event/bad-address-triggers-full ()
  (let (full-reason)
    (cl-letf (((symbol-function 'hyprland-reconcile-request-fast)
               (lambda (&rest _) nil))
              ((symbol-function 'hyprland-reconcile-request-full)
               (lambda (reason) (setq full-reason reason))))
      (hyprland-sync--process-event (list :name 'windowtitlev2 :payload "not-an-addr,title"))
      (should (string-match-p "parse-failed" full-reason)))))

(provide 'hyprland-sync-test)
;;; hyprland-sync-test.el ends here
