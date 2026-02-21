;;; hyprland-ibuffer-test.el --- Tests for ibuffer bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'hyprland-ibuffer)

(defun hyprland-ibuffer-test--with-clean-state (fn)
  "Run FN with isolated ibuffer mirror state and cleanup."
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        (hyprland-sync--windows (make-hash-table :test #'equal))
        (created nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'generate-new-buffer)
                     (lambda (name)
                       (let ((buf (get-buffer-create (generate-new-buffer-name name))))
                         (push buf created)
                         buf))))
            (funcall fn)))
      (dolist (buf created)
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest hyprland-ibuffer-test-sync-creates-buffers ()
  (hyprland-ibuffer-test--with-clean-state
   (lambda ()
     (puthash "0xaaa" '((address . "0xaaa") (title . "A") (class . "zen")
                        (workspace . ((id . 1) (name . "1"))) (pid . 1))
              hyprland-sync--windows)
     (hyprland-ibuffer-sync-buffers)
     (let ((buf (gethash "0xaaa" hyprland-ibuffer--address->buffer)))
       (should (buffer-live-p buf))
       (with-current-buffer buf
         (should (derived-mode-p 'hyprland-window-buffer-mode))
         (should (equal hyprland-window-address "0xaaa")))))))

(ert-deftest hyprland-ibuffer-test-sync-removes-stale-buffers ()
  (hyprland-ibuffer-test--with-clean-state
   (lambda ()
     (puthash "0xaaa" '((address . "0xaaa") (title . "A") (class . "zen")) hyprland-sync--windows)
     (hyprland-ibuffer-sync-buffers)
     (let ((buf (gethash "0xaaa" hyprland-ibuffer--address->buffer)))
       (should (buffer-live-p buf))
       (clrhash hyprland-sync--windows)
       (hyprland-ibuffer-sync-buffers)
       (should-not (buffer-live-p buf))
       (should-not (gethash "0xaaa" hyprland-ibuffer--address->buffer))))))

(ert-deftest hyprland-ibuffer-test-actions-use-buffer-address ()
  (hyprland-ibuffer-test--with-clean-state
   (lambda ()
     (let ((calls nil)
           (buf (get-buffer-create "*hypr-test*")))
       (unwind-protect
           (progn
             (with-current-buffer buf
               (hyprland-window-buffer-mode)
               (setq hyprland-window-address "0xabc")
               (cl-letf (((symbol-function 'hyprland-jump)
                          (lambda (addr) (push (list 'jump addr) calls)))
                         ((symbol-function 'hyprland-close)
                          (lambda (addr) (push (list 'close addr) calls)))
                         ((symbol-function 'hyprland-tag)
                          (lambda (addr op) (push (list 'tag addr op) calls))))
                 (hyprland-buffer-jump)
                 (hyprland-buffer-close)
                 (hyprland-buffer-tag "+x")))
             (should (member '(jump "0xabc") calls))
             (should (member '(close "0xabc") calls))
             (should (member '(tag "0xabc" "+x") calls)))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest hyprland-ibuffer-test-ibuffer-row-jump-dispatches ()
  (let* ((mirror (get-buffer-create "*hypr-mirror*"))
         (ibuf (get-buffer-create "*hypr-ibuf*"))
         called)
    (unwind-protect
        (progn
          (with-current-buffer mirror
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xabc"))
          (with-current-buffer ibuf
            (ibuffer-mode)
            (cl-letf (((symbol-function 'ibuffer-current-buffer)
                       (lambda (&optional _mark) mirror))
                      ((symbol-function 'hyprland-buffer-jump)
                       (lambda () (setq called t))))
              (hyprland-ibuffer-jump-at-point)
              (should called))))
      (when (buffer-live-p mirror) (kill-buffer mirror))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(provide 'hyprland-ibuffer-test)
;;; hyprland-ibuffer-test.el ends here
