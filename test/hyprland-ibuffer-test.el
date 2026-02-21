;;; hyprland-ibuffer-test.el --- Tests for ibuffer bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'hyprland-ibuffer)

(defvar ibuffer-saved-filter-groups nil)

(defun hyprland-ibuffer-test--kill-buffer-quiet (buf)
  "Kill BUF while suppressing mirror close side effects."
  (when (buffer-live-p buf)
    (let ((hyprland-ibuffer--suppress-kill-action t))
      (kill-buffer buf))))

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
        (hyprland-ibuffer-test--kill-buffer-quiet buf)))))

(ert-deftest hyprland-ibuffer-test-sync-creates-buffers ()
  (hyprland-ibuffer-test--with-clean-state
   (lambda ()
     (puthash "0xaaa" '((address . "0xaaa")
                        (title . "A")
                        (class . "zen")
                        (workspace . ((id . 1) (name . "1")))
                        (pid . 1))
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
     (puthash "0xaaa" '((address . "0xaaa") (title . "A") (class . "zen"))
              hyprland-sync--windows)
     (hyprland-ibuffer-sync-buffers)
     (let ((buf (gethash "0xaaa" hyprland-ibuffer--address->buffer)))
       (should (buffer-live-p buf))
       (clrhash hyprland-sync--windows)
       (hyprland-ibuffer-sync-buffers)
       (should-not (buffer-live-p buf))
       (should-not (gethash "0xaaa" hyprland-ibuffer--address->buffer))))))

(ert-deftest hyprland-ibuffer-test-sync-recreates-deleted-mapped-buffer ()
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        (hyprland-sync--windows (make-hash-table :test #'equal))
        old new)
    (puthash "0xabc" '((address . "0xabc") (title . "T") (class . "C"))
             hyprland-sync--windows)
    (setq old (generate-new-buffer "*hypr-old*"))
    (puthash "0xabc" old hyprland-ibuffer--address->buffer)
    (hyprland-ibuffer-test--kill-buffer-quiet old)
    (hyprland-ibuffer-sync-buffers)
    (setq new (gethash "0xabc" hyprland-ibuffer--address->buffer))
    (should (buffer-live-p new))
    (should-not (eq new old))
    (hyprland-ibuffer-test--kill-buffer-quiet new)))

(ert-deftest hyprland-ibuffer-test-actions-use-buffer-address ()
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
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-killing-mirror-buffer-closes-window ()
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        (closed nil)
        (buf (generate-new-buffer "*hypr-kill*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xabc"))
          (puthash "0xabc" buf hyprland-ibuffer--address->buffer)
          (cl-letf (((symbol-function 'hyprland-close)
                     (lambda (addr) (setq closed addr))))
            (kill-buffer buf)
            (should (equal closed "0xabc"))
            (should-not (gethash "0xabc" hyprland-ibuffer--address->buffer))))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-stale-kill-does-not-close-window ()
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        (hyprland-sync--windows (make-hash-table :test #'equal))
        (closed nil)
        (buf (generate-new-buffer "*hypr-stale*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xdef"))
          (puthash "0xdef" buf hyprland-ibuffer--address->buffer)
          (cl-letf (((symbol-function 'hyprland-close)
                     (lambda (_addr) (setq closed t))))
            (hyprland-ibuffer-sync-buffers)
            (should-not closed)))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-maybe-jump-for-buffer ()
  (let ((buf (generate-new-buffer "*hypr-open*"))
        seen)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0xaaa"))
          (cl-letf (((symbol-function 'hyprland-jump)
                     (lambda (addr) (setq seen addr))))
            (should (hyprland-ibuffer--maybe-jump-for-buffer buf))
            (should (equal seen "0xaaa"))))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-advice-switch-to-buffer/intercepts-mirror ()
  (let ((buf (generate-new-buffer "*hypr-switch*"))
        jumped
        orig-called)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x111"))
          (cl-letf (((symbol-function 'hyprland-jump)
                     (lambda (addr) (setq jumped addr))))
            (hyprland-ibuffer--advice-switch-to-buffer
             (lambda (&rest _args)
               (setq orig-called t)
               (current-buffer))
             buf)
            (should (equal jumped "0x111"))
            (should-not orig-called)))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-advice-switch-to-buffer/consult-preview-does-not-jump ()
  (let ((buf (generate-new-buffer "*hypr-switch-preview*"))
        jumped
        previewed
        orig-called)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x555"))
          (cl-letf (((symbol-function 'hyprland-ibuffer--consult-preview-active-p)
                     (lambda () t))
                    ((symbol-function 'hyprland-ibuffer--preview-buffer-window)
                     (lambda (_buf) (setq previewed t) t))
                    ((symbol-function 'hyprland-jump)
                     (lambda (_addr) (setq jumped t))))
            (hyprland-ibuffer--advice-switch-to-buffer
             (lambda (&rest _args)
               (setq orig-called t)
               :orig)
             buf)
            (should previewed)
            (should-not jumped)
            (should-not orig-called)))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-advice-switch-to-buffer/respects-disable-flag ()
  (let ((buf (generate-new-buffer "*hypr-switch-disabled*"))
        orig-called)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x222"))
          (let ((hyprland-ibuffer-intercept-buffer-open nil))
            (cl-letf (((symbol-function 'hyprland-jump)
                       (lambda (_addr)
                         (ert-fail "hyprland-jump should not be called when interception is disabled"))))
              (hyprland-ibuffer--advice-switch-to-buffer
               (lambda (&rest _args)
                 (setq orig-called t)
                 :orig)
               buf)
              (should orig-called))))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-advice-pop-to-buffer/intercepts-mirror ()
  (let ((buf (generate-new-buffer "*hypr-pop*"))
        jumped
        orig-called)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x333"))
          (cl-letf (((symbol-function 'hyprland-jump)
                     (lambda (addr) (setq jumped addr))))
            (hyprland-ibuffer--advice-pop-to-buffer
             (lambda (&rest _args)
               (setq orig-called t)
               (selected-window))
             buf)
            (should (equal jumped "0x333"))
            (should-not orig-called)))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-preview-buffer-window/dispatches-preview-request ()
  (let ((buf (generate-new-buffer "*hypr-preview-window*"))
        requested-window
        displayed)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x666"
                  hyprland-window-title "T"
                  hyprland-window-class "C"
                  hyprland-window-workspace "6"))
          (cl-letf (((symbol-function 'hyprland-preview-request)
                     (lambda (window cb)
                       (setq requested-window window)
                       (funcall cb (list :ok nil :message "x"))))
                    ((symbol-function 'hyprland-consult--display-preview)
                     (lambda (_payload) (setq displayed t))))
            (should (hyprland-ibuffer--preview-buffer-window buf))
            (should (equal (alist-get 'address requested-window) "0x666"))
            (should displayed)))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

(ert-deftest hyprland-ibuffer-test-advice-switch-to-buffer/handles-buffer-name ()
  (let ((buf (generate-new-buffer "*hypr-by-name*"))
        jumped)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hyprland-window-buffer-mode)
            (setq hyprland-window-address "0x444"))
          (cl-letf (((symbol-function 'hyprland-jump)
                     (lambda (addr) (setq jumped addr))))
            (hyprland-ibuffer--advice-switch-to-buffer
             (lambda (&rest _args)
               (ert-fail "orig should not run for mirror buffer names"))
             (buffer-name buf))
            (should (equal jumped "0x444"))))
      (hyprland-ibuffer-test--kill-buffer-quiet buf))))

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
      (hyprland-ibuffer-test--kill-buffer-quiet mirror)
      (hyprland-ibuffer-test--kill-buffer-quiet ibuf))))

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
      (hyprland-ibuffer-test--kill-buffer-quiet mirror-a)
      (hyprland-ibuffer-test--kill-buffer-quiet mirror-b)
      (hyprland-ibuffer-test--kill-buffer-quiet ibuf))))

(ert-deftest hyprland-ibuffer-test-keymap-remaps-ibuffer-commands ()
  (should (eq (lookup-key hyprland-ibuffer-view-mode-map [remap ibuffer-visit-buffer])
              #'hyprland-ibuffer-jump-at-point))
  (should (eq (lookup-key hyprland-ibuffer-view-mode-map [remap ibuffer-do-kill-lines])
              #'hyprland-ibuffer-close-marked-or-current)))

(ert-deftest hyprland-ibuffer-test-open-applies-custom-formats ()
  (let ((ibuf (get-buffer-create "*Ibuffer-hyprland*"))
        captured switched installed installed-quiet)
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
                    ((symbol-function 'require)
                     (lambda (&rest _args) t))
                    ((symbol-function 'hyprland-ibuffer-install-saved-filter-group)
                     (lambda (&optional quiet)
                       (setq installed t
                             installed-quiet quiet)))
                    ((symbol-function 'ibuffer-switch-to-saved-filter-groups)
                     (lambda (name) (setq switched name)))
                    ((symbol-function 'ibuffer-update) #'ignore))
            (hyprland-ibuffer-open)
            (should captured)
            (should installed)
            (should installed-quiet)
            (should (equal switched hyprland-ibuffer-saved-filter-group-profile))
            (with-current-buffer ibuf
              (should hyprland-ibuffer-view-mode)
              (should (local-variable-p 'ibuffer-formats))
              (let ((fmt (car ibuffer-formats)))
                (should (member '(hypr-ws 6 6 :left) fmt))
                (should (member '(hypr-class 12 12 :left :elide) fmt))
                (should (member '(hypr-title 28 28 :left :elide) fmt))
                (should (member '(hypr-address 16 16 :left) fmt))))))
      (hyprland-ibuffer-test--kill-buffer-quiet ibuf))))

(ert-deftest hyprland-ibuffer-test-install-saved-filter-group/creates-profile ()
  (let ((ibuffer-saved-filter-groups nil)
        (hyprland-ibuffer-saved-filter-group-profile "hyprland")
        (hyprland-ibuffer-filter-group-name "Hyprland")
        (hyprland-ibuffer-filter-group-position 'prepend))
    (cl-letf (((symbol-function 'message) #'ignore))
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
    (cl-letf (((symbol-function 'message) #'ignore))
      (hyprland-ibuffer-install-saved-filter-group)
      (let* ((entry (assoc "hyprland" ibuffer-saved-filter-groups))
             (groups (cdr entry))
             (hypr (car groups)))
        (should (= (cl-count-if (lambda (g) (equal (car g) "Hyprland")) groups) 1))
        (should (equal (car hypr) "Hyprland"))
        (should (equal (cadr hypr)
                       '(mode . hyprland-window-buffer-mode)))))))

(ert-deftest hyprland-ibuffer-test-open-native/switches-saved-profile ()
  (let (called)
    (cl-letf (((symbol-function 'hyprland-ibuffer-open)
               (lambda () (setq called t))))
      (hyprland-ibuffer-open-native)
      (should called))))

(ert-deftest hyprland-ibuffer-test-doctor/prunes-and-repairs-profile ()
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        (ibuffer-saved-filter-groups nil)
        (hyprland-ibuffer-saved-filter-group-profile "hyprland")
        (hyprland-ibuffer-filter-group-name "Hyprland")
        dead report)
    (setq dead (generate-new-buffer "*hypr-dead*"))
    (puthash "0xdead" dead hyprland-ibuffer--address->buffer)
    (hyprland-ibuffer-test--kill-buffer-quiet dead)
    (setq report (hyprland-ibuffer-doctor))
    (should (equal (plist-get report :dead-before) 1))
    (should (equal (plist-get report :dead-after) 0))
    (should (equal (plist-get report :pruned) 1))
    (should (equal (plist-get report :profile) "hyprland"))
    (should-not (gethash "0xdead" hyprland-ibuffer--address->buffer))
    (let* ((entry (assoc "hyprland" ibuffer-saved-filter-groups))
           (group (car (cdr entry))))
      (should entry)
      (should (equal (car group) "Hyprland"))
      (should (equal (cadr group)
                     '(mode . hyprland-window-buffer-mode))))))

(ert-deftest hyprland-ibuffer-test-doctor/interactive-message ()
  (let ((hyprland-ibuffer--address->buffer (make-hash-table :test #'equal))
        captured)
    (cl-letf (((symbol-function 'called-interactively-p)
               (lambda (_kind) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq captured (apply #'format fmt args)))))
      (hyprland-ibuffer-doctor)
      (should (string-match-p "Hyprland ibuffer doctor" captured)))))

(provide 'hyprland-ibuffer-test)
;;; hyprland-ibuffer-test.el ends here
