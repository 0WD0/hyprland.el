;;; hyprland-zen-test.el --- Tests for Zen bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'hyprland-zen)

(defvar hyprland-zen-test--refresh-count 0)

(defun hyprland-zen-test--count-refresh ()
  "Increment refresh counter for hook tests."
  (setq hyprland-zen-test--refresh-count (1+ hyprland-zen-test--refresh-count)))

(ert-deftest hyprland-zen-test-tab-key/defaults ()
  (should (equal (hyprland-zen--tab-key '((tab_id . 42)))
                 "zen/default/42")))

(ert-deftest hyprland-zen-test-apply-message/snapshot-upsert-remove ()
  (let ((hyprland-zen--tabs (make-hash-table :test #'equal))
        (hyprland-zen-after-refresh-hook '(hyprland-zen-test--count-refresh))
        (hyprland-zen-test--refresh-count 0))
    (hyprland-zen--apply-message
     '((type . "snapshot")
       (tabs . (((browser . "zen") (profile . "main") (tab_id . "1") (title . "A"))
                ((browser . "zen") (profile . "main") (tab_id . "2") (title . "B"))))))
    (should (= (hash-table-count hyprland-zen--tabs) 2))
    (should (= hyprland-zen-test--refresh-count 1))

    (hyprland-zen--apply-message
     '((type . "upsert")
       (tab . ((browser . "zen") (profile . "main") (tab_id . "1") (title . "A2")))))
    (should (equal (hyprland-zen--field (hyprland-zen-tab-get "zen/main/1") 'title) "A2"))
    (should (= hyprland-zen-test--refresh-count 2))

    (hyprland-zen--apply-message
     '((type . "remove")
       (key . "zen/main/1")))
    (should-not (hyprland-zen-tab-get "zen/main/1"))
    (should (= (hash-table-count hyprland-zen--tabs) 1))
    (should (= hyprland-zen-test--refresh-count 3))))

(ert-deftest hyprland-zen-test-process-filter/line-buffering ()
  (let ((hyprland-zen--fragment "")
        seen)
    (cl-letf (((symbol-function 'hyprland-zen--handle-line)
               (lambda (line) (push line seen))))
      (hyprland-zen--process-filter nil "{\"type\":\"snapshot\"}\n{\"type\":\"up")
      (should (equal (nreverse seen) '("{\"type\":\"snapshot\"}")))
      (should (equal hyprland-zen--fragment "{\"type\":\"up"))
      (setq seen nil)
      (hyprland-zen--process-filter nil "sert\"}\n")
      (should (equal (nreverse seen) '("{\"type\":\"upsert\"}")))
      (should (string-empty-p hyprland-zen--fragment)))))

(ert-deftest hyprland-zen-test-send/encodes-json-line ()
  (let ((hyprland-zen--process 'proc)
        sent)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (proc) (eq proc 'proc)))
              ((symbol-function 'process-send-string)
               (lambda (_proc string) (setq sent string))))
      (hyprland-zen--send '((op . "list-tabs")))
      (should (string-match-p "\"op\":\"list-tabs\"" sent))
      (should (string-suffix-p "\n" sent)))))

(ert-deftest hyprland-zen-test-tab-switch/sends-activate-command ()
  (let ((tab '((browser . "zen") (profile . "default") (tab_id . "9")))
        payload)
    (cl-letf (((symbol-function 'hyprland-zen--read-tab)
               (lambda (_prompt) tab))
              ((symbol-function 'hyprland-zen--send)
               (lambda (msg) (setq payload msg))))
      (should (equal (hyprland-zen-tab-switch) "zen/default/9"))
      (should (equal (hyprland-zen--field payload 'op) "activate-tab"))
      (should (equal (hyprland-zen--field payload 'key) "zen/default/9")))))

(ert-deftest hyprland-zen-test-start/starts-process-and-refreshes ()
  (let ((hyprland-zen-host-command '("host" "--stdio"))
        (hyprland-zen-auto-refresh-on-start t)
        (hyprland-zen--process nil)
        launched refreshed)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq launched args)
                 'proc))
              ((symbol-function 'hyprland-zen-refresh)
               (lambda () (setq refreshed t))))
      (should (eq (hyprland-zen-start) 'proc))
      (should (equal (plist-get launched :command) '("host" "--stdio")))
      (should refreshed))))

(ert-deftest hyprland-zen-test-mode/toggles-start-stop ()
  (let (started stopped)
    (unwind-protect
        (cl-letf (((symbol-function 'hyprland-zen-start)
                   (lambda () (setq started t)))
                  ((symbol-function 'hyprland-zen-stop)
                   (lambda () (setq stopped t))))
          (hyprland-zen-mode 1)
          (hyprland-zen-mode 0)
          (should started)
          (should stopped))
      (setq hyprland-zen-mode nil))))

(provide 'hyprland-zen-test)
;;; hyprland-zen-test.el ends here
