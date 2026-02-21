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
          (should (equal hyprland-window-address "0xaaa"))
          (should (equal hyprland-window-workspace "1"))
          (should (equal hyprland-window-class "zen"))
          (should (equal hyprland-window-title "A")))))))

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

(ert-deftest hyprland-ibuffer-test-close-marked-or-current/uses-marked ()
  (let* ((mirror-a (get-buffer-create "*hypr-mirror-a*"))
         (mirror-b (get-buffer-create "*hypr-mirror-b*"))
         (ibuf (get-buffer-create "*hypr-ibuf*"))
         (closed nil))
    (unwind-protect
        (progn
          (with-current-buffer mirror-a
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xaaa"))
          (with-current-buffer mirror-b
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xbbb"))
          (with-current-buffer ibuf
            (ibuffer-mode)
            (cl-letf (((symbol-function 'ibuffer-get-marked-buffers)
                       (lambda () (list mirror-a mirror-b)))
                      ((symbol-function 'ibuffer-current-buffer)
                       (lambda (&optional _mark) mirror-a))
                      ((symbol-function 'hyprland-close)
                       (lambda (address) (push address closed))))
              (hyprland-ibuffer-close-marked-or-current)
              (should (equal (sort closed #'string<)
                             '("0xaaa" "0xbbb"))))))
      (when (buffer-live-p mirror-a) (kill-buffer mirror-a))
      (when (buffer-live-p mirror-b) (kill-buffer mirror-b))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(ert-deftest hyprland-ibuffer-test-keymap-remaps-ibuffer-commands ()
  (should (eq (lookup-key hyprland-ibuffer-view-mode-map [remap ibuffer-visit-buffer])
              #'hyprland-ibuffer-jump-at-point))
  (should (eq (lookup-key hyprland-ibuffer-view-mode-map [remap ibuffer-do-kill-lines])
              #'hyprland-ibuffer-close-marked-or-current)))

(ert-deftest hyprland-ibuffer-test-open-applies-custom-formats ()
  (let ((ibuf (get-buffer-create "*Ibuffer-hyprland*"))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer ibuf
            (ibuffer-mode))
          (cl-letf (((symbol-function 'ibuffer)
                     (lambda (&optional _name _bufname)
                       (setq captured t)
                       (with-current-buffer ibuf
                         (ibuffer-mode))
                       ibuf))
                    ((symbol-function 'ibuffer-filter-disable) #'ignore)
                    ((symbol-function 'ibuffer-filter-by-derived-mode) #'ignore)
                    ((symbol-function 'ibuffer-update) #'ignore))
            (hyprland-ibuffer-open)
            (should captured)
            (with-current-buffer ibuf
              (should hyprland-ibuffer-view-mode)
              (should (local-variable-p 'ibuffer-formats))
              (let ((fmt (car ibuffer-formats)))
                (should (member '(hypr-ws 6 6 :left) fmt))
                (should (member '(hypr-class 12 12 :left :elide) fmt))
                (should (member '(hypr-title 28 28 :left :elide) fmt))
                (should (member '(hypr-address 16 16 :left) fmt))))))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(ert-deftest hyprland-ibuffer-test-ensure-filter-group/add-once ()
  (let ((ibuf (get-buffer-create "*hypr-ibuf-groups*"))
        (updates 0)
        (hyprland-ibuffer-auto-filter-group t)
        (hyprland-ibuffer-filter-group-name "Hyprland")
        (hyprland-ibuffer-filter-group-position 'prepend))
    (unwind-protect
        (with-current-buffer ibuf
          (ibuffer-mode)
          (setq-local ibuffer-filter-groups
                      '(("Default" (predicate . identity))))
          (cl-letf (((symbol-function 'ibuffer-update)
                     (lambda (&rest _args) (cl-incf updates))))
            (hyprland-ibuffer--ensure-filter-group)
            (hyprland-ibuffer--ensure-filter-group))
          (should (= updates 1))
          (should (equal (caar ibuffer-filter-groups) "Hyprland"))
          (should (= (cl-count-if (lambda (g)
                                    (equal (car g) "Hyprland"))
                                  ibuffer-filter-groups)
                     1)))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(ert-deftest hyprland-ibuffer-test-remove-filter-group ()
  (let ((ibuf (get-buffer-create "*hypr-ibuf-remove*"))
        (updates 0)
        (hyprland-ibuffer-filter-group-name "Hyprland"))
    (unwind-protect
        (with-current-buffer ibuf
          (ibuffer-mode)
          (setq-local ibuffer-filter-groups
                      '(("Hyprland" (mode . hyprland-window-buffer-mode))
                        ("Default" (predicate . identity))))
          (cl-letf (((symbol-function 'ibuffer-update)
                     (lambda (&rest _args) (cl-incf updates))))
            (hyprland-ibuffer--remove-filter-group))
          (should (= updates 1))
          (should-not (assoc "Hyprland" ibuffer-filter-groups)))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(ert-deftest hyprland-ibuffer-test-install-saved-filter-group/creates-profile ()
  (let ((ibuffer-saved-filter-groups nil)
        (hyprland-ibuffer-saved-filter-group-profile "hyprland")
        (hyprland-ibuffer-filter-group-name "Hyprland")
        (hyprland-ibuffer-filter-group-position 'prepend))
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _args) t))
              ((symbol-function 'message) #'ignore))
      (hyprland-ibuffer-install-saved-filter-group)
      (let* ((entry (assoc "hyprland" ibuffer-saved-filter-groups))
             (group (car (cdr entry))))
        (should entry)
        (should (equal (car group) "Hyprland"))
        (should (equal (cadr group)
                       '(mode . hyprland-window-buffer-mode)))))))

(ert-deftest hyprland-ibuffer-test-install-saved-filter-group/no-duplicates ()
  (let ((ibuffer-saved-filter-groups
         '(("hyprland"
            ("Hyprland" ((mode . hyprland-window-buffer-mode)))
            ("Default" (predicate . identity)))))
        (hyprland-ibuffer-saved-filter-group-profile "hyprland")
        (hyprland-ibuffer-filter-group-name "Hyprland")
        (hyprland-ibuffer-filter-group-position 'prepend))
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _args) t))
              ((symbol-function 'message) #'ignore))
      (hyprland-ibuffer-install-saved-filter-group)
      (let* ((entry (assoc "hyprland" ibuffer-saved-filter-groups))
             (groups (cdr entry))
             (hypr (car groups)))
        (should (= (cl-count-if (lambda (g) (equal (car g) "Hyprland")) groups) 1))
        (should (equal (car hypr) "Hyprland"))
        (should (equal (cadr hypr)
                       '(mode . hyprland-window-buffer-mode)))))))

(ert-deftest hyprland-ibuffer-test-open-native/switches-saved-profile ()
  (let ((ibuf (get-buffer-create "*Ibuffer-hyprland*"))
        installed switched)
    (unwind-protect
        (progn
          (with-current-buffer ibuf
            (ibuffer-mode))
          (cl-letf (((symbol-function 'ibuffer)
                     (lambda (&optional _name _bufname)
                       (with-current-buffer ibuf
                         (ibuffer-mode))
                       ibuf))
                    ((symbol-function 'hyprland-ibuffer-install-saved-filter-group)
                     (lambda () (setq installed t)))
                    ((symbol-function 'ibuffer-switch-to-saved-filter-groups)
                     (lambda (name) (setq switched name)))
                    ((symbol-function 'ibuffer-update) #'ignore))
            (hyprland-ibuffer-open-native)
            (should installed)
            (should (equal switched hyprland-ibuffer-saved-filter-group-profile))))
      (when (buffer-live-p ibuf) (kill-buffer ibuf)))))

(provide 'hyprland-ibuffer-test)
;;; hyprland-ibuffer-test.el ends here
