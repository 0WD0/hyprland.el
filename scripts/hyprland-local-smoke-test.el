;;; hyprland-local-smoke-test.el --- Local runtime smoke test -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Manual smoke test for real Hyprland integration against a live session.
;; This script is intentionally not part of the regular ERT suite.

;;; Code:

(require 'cl-lib)
(require 'ibuf-ext)
(require 'hyprland)

(defun hyprland-local-smoke--fail (fmt &rest args)
  "Signal fatal smoke-test error using FMT and ARGS."
  (error "[hyprland-local-smoke] %s" (apply #'format fmt args)))

(defun hyprland-local-smoke--assert (pred fmt &rest args)
  "Assert PRED, otherwise fail with FMT and ARGS."
  (unless pred
    (apply #'hyprland-local-smoke--fail fmt args)))

(defun hyprland-local-smoke-run ()
  "Run local runtime smoke checks against live hyprctl and ibuffer flow."
  (let ((buf nil))
    (unwind-protect
        (progn
          (hyprland-local-smoke--assert (getenv "HYPRLAND_INSTANCE_SIGNATURE")
                                        "HYPRLAND_INSTANCE_SIGNATURE is missing")
          (hyprland-local-smoke--assert (getenv "XDG_RUNTIME_DIR")
                                        "XDG_RUNTIME_DIR is missing")

          (let ((clients (hyprland--hyprctl-json "clients")))
            (hyprland-local-smoke--assert (listp clients)
                                          "hyprctl clients did not return a list")
            (hyprland-local-smoke--assert (> (length clients) 0)
                                          "hyprctl clients returned empty list"))

          (hyprland-refresh)
          (let ((windows (hyprland-windows)))
            (hyprland-local-smoke--assert (> (length windows) 0)
                                          "hyprland-refresh produced empty window list"))

          (hyprland-ibuffer-sync-buffers)
          (hyprland-local-smoke--assert (> (hash-table-count hyprland-ibuffer--address->buffer) 0)
                                        "no mirror buffers created after sync")

          ;; Verify saved-group shape and ensure we can switch without filter errors.
          (setq ibuffer-saved-filter-groups nil)
          (hyprland-ibuffer-install-saved-filter-group)
          (let* ((entry (assoc hyprland-ibuffer-saved-filter-group-profile
                               ibuffer-saved-filter-groups))
                 (group (car (cdr entry)))
                 (filter (and (listp group) (cadr group))))
            (hyprland-local-smoke--assert entry
                                          "saved filter profile %s not installed"
                                          hyprland-ibuffer-saved-filter-group-profile)
            (hyprland-local-smoke--assert (equal (car group) hyprland-ibuffer-filter-group-name)
                                          "unexpected saved group name: %S"
                                          (car group))
            (hyprland-local-smoke--assert (and (consp filter)
                                               (eq (car filter) 'mode)
                                               (eq (cdr filter) 'hyprland-window-buffer-mode))
                                          "invalid saved filter shape: %S"
                                          filter))

          (hyprland-ibuffer-open)
          (setq buf (get-buffer "*Ibuffer-hyprland*"))
          (hyprland-local-smoke--assert (buffer-live-p buf)
                                        "hyprland-ibuffer-open did not create target buffer")
          (with-current-buffer buf
            (hyprland-local-smoke--assert (assoc hyprland-ibuffer-filter-group-name
                                                 ibuffer-filter-groups)
                                          "Hyprland filter group not active in ibuffer")
            (hyprland-local-smoke--assert hyprland-ibuffer-view-mode
                                          "hyprland-ibuffer-view-mode is not enabled"))

          (princ "[hyprland-local-smoke] OK\n"))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(hyprland-local-smoke-run)

;;; hyprland-local-smoke-test.el ends here
