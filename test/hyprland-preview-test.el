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

(provide 'hyprland-preview-test)
;;; hyprland-preview-test.el ends here
