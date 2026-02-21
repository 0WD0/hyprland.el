;;; hyprland-preview-test.el --- Tests for hyprland preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'hyprland-preview)

(ert-deftest hyprland-preview-test-stable-id/number ()
  (should (equal (hyprland-preview--stable-id->identifier 3735928559) "deadbeef")))

(ert-deftest hyprland-preview-test-stable-id/strip-0x ()
  (should (equal (hyprland-preview--stable-id->identifier "0xABC123") "abc123")))

(ert-deftest hyprland-preview-test-stable-id/reject-invalid ()
  (should-not (hyprland-preview--stable-id->identifier "xyz-1")))

(ert-deftest hyprland-preview-test-geometry/valid ()
  (let ((window '((at . (10 20)) (size . (1920 1080)))))
    (should (equal (hyprland-preview--geometry window) "10,20 1920x1080"))))

(ert-deftest hyprland-preview-test-capture-args/fallback-to-geometry ()
  (let ((window '((stable_id . "oops") (at . (1 2)) (size . (3 4))))
        (hyprland-preview--grim-supports-target nil))
    (cl-letf (((symbol-function 'hyprland-preview--grim-supports-target-p)
               (lambda () nil)))
      (should (equal (hyprland-preview--capture-args window)
                     '("-g" "1,2 3x4" "-"))))))

(ert-deftest hyprland-preview-test-needs-focus/hidden-window ()
  (let ((window '((hidden . 1))))
    (cl-letf (((symbol-function 'hyprland-preview--active-workspace-id)
               (lambda () 1)))
      (should (hyprland-preview--needs-focus-for-capture-p window)))))

(ert-deftest hyprland-preview-test-needs-focus/workspace-mismatch ()
  (let ((window '((workspace . ((id . 3))))))
    (cl-letf (((symbol-function 'hyprland-preview--active-workspace-id)
               (lambda () 1)))
      (should (hyprland-preview--needs-focus-for-capture-p window)))))

(ert-deftest hyprland-preview-test-restore-focus-dispatches-and-clears ()
  (let ((hyprland-preview--active-restore-address "0xabc")
        seen)
    (cl-letf (((symbol-function 'hyprland--dispatch)
               (lambda (_dispatcher arg) (setq seen arg))))
      (hyprland-preview--restore-focus)
      (should (equal seen "address:0xabc"))
      (should-not hyprland-preview--active-restore-address))))

(provide 'hyprland-preview-test)
;;; hyprland-preview-test.el ends here
