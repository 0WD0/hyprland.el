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

(ert-deftest hyprland-zen-test-workspace-key/defaults ()
  (should (equal (hyprland-zen--workspace-key '((workspace_id . "main")))
                 "zen/default/main")))

(ert-deftest hyprland-zen-test-apply-message/snapshot-upsert-remove ()
  (let ((hyprland-zen--tabs (make-hash-table :test #'equal))
        (hyprland-zen--workspaces (make-hash-table :test #'equal))
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

(ert-deftest hyprland-zen-test-apply-message/workspace-upsert-remove ()
  (let ((hyprland-zen--workspaces (make-hash-table :test #'equal))
        (hyprland-zen-after-refresh-hook '(hyprland-zen-test--count-refresh))
        (hyprland-zen-test--refresh-count 0))
    (hyprland-zen--apply-message
     '((type . "workspace_snapshot")
       (workspaces . (((browser . "zen") (profile . "main") (workspace_id . "a") (name . "A"))
                      ((browser . "zen") (profile . "main") (workspace_id . "b") (name . "B"))))))
    (should (= (hash-table-count hyprland-zen--workspaces) 2))
    (should (= hyprland-zen-test--refresh-count 1))

    (hyprland-zen--apply-message
     '((type . "workspace-upsert")
       (workspace . ((browser . "zen") (profile . "main") (workspace_id . "a") (name . "AA") (active . t)))))
    (should (equal (hyprland-zen--field (hyprland-zen-workspace-get "zen/main/a") 'name) "AA"))
    (should (hyprland-zen--field (hyprland-zen-workspace-get "zen/main/a") 'active))
    (should (= hyprland-zen-test--refresh-count 2))

    (hyprland-zen--apply-message
     '((type . "workspace-remove")
       (key . "zen/main/a")))
    (should-not (hyprland-zen-workspace-get "zen/main/a"))
    (should (= (hash-table-count hyprland-zen--workspaces) 1))
    (should (= hyprland-zen-test--refresh-count 3))))

(ert-deftest hyprland-zen-test-store-tab/derives-workspace ()
  (let ((hyprland-zen--tabs (make-hash-table :test #'equal))
        (hyprland-zen--workspaces (make-hash-table :test #'equal)))
    (hyprland-zen--store-tab '((browser . "zen")
                               (profile . "main")
                               (workspace_id . "w1")
                               (workspace_name . "WS1")
                               (tab_id . "12")
                               (title . "T")))
    (should (hyprland-zen-workspace-get "zen/main/w1"))
    (should (equal (hyprland-zen--field (hyprland-zen-workspace-get "zen/main/w1") 'name)
                   "WS1"))))

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
        launched refreshed refreshed-workspaces)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq launched args)
                 'proc))
              ((symbol-function 'hyprland-zen-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'hyprland-zen-refresh-workspaces)
               (lambda () (setq refreshed-workspaces t))))
      (should (eq (hyprland-zen-start) 'proc))
      (should (equal (plist-get launched :command) '("host" "--stdio")))
      (should refreshed)
      (should refreshed-workspaces))))

(ert-deftest hyprland-zen-test-workspace-switch/sends-activate-command ()
  (let ((workspace '((browser . "zen") (profile . "default") (workspace_id . "w9")))
        payload)
    (cl-letf (((symbol-function 'hyprland-zen--read-workspace)
               (lambda (_prompt) workspace))
              ((symbol-function 'hyprland-zen--send)
               (lambda (msg) (setq payload msg))))
      (should (equal (hyprland-zen-workspace-switch) "zen/default/w9"))
      (should (equal (hyprland-zen--field payload 'op) "activate-workspace"))
      (should (equal (hyprland-zen--field payload 'key) "zen/default/w9")))))

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
