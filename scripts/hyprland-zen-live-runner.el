;;; hyprland-zen-live-runner.el --- Friendly runner for Zen live smoke test -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run live smoke test with concise failure output for CI/troubleshooting.

;;; Code:

(setq debug-on-error nil)
(setq debug-early-backtrace nil)

(let* ((self (or load-file-name (buffer-file-name)))
       (dir (and self (file-name-directory self)))
       (smoke (and dir (expand-file-name "hyprland-zen-live-smoke-test.el" dir))))
  (unless (and smoke (file-readable-p smoke))
    (princ "[hyprland-zen-live-runner] FAIL missing scripts/hyprland-zen-live-smoke-test.el\n")
    (kill-emacs 2))

  (setq hyprland-zen-live-smoke-auto-run nil)
  (load smoke nil t)

  (condition-case err
      (progn
        (hyprland-zen-live-smoke-run)
        (kill-emacs 0))
    (error
     (princ (format "[hyprland-zen-live-runner] FAIL %s\n" (error-message-string err)))
     (when-let* ((status (ignore-errors (hyprland-zen-status))))
       (princ (format "[hyprland-zen-live-runner] status=%S\n" status)))
     (when-let* ((buf (ignore-errors (hyprland-zen-trace-report 16))))
       (princ "[hyprland-zen-live-runner] trace-begin\n")
       (with-current-buffer buf
         (princ (buffer-substring-no-properties (point-min) (point-max))))
       (princ "[hyprland-zen-live-runner] trace-end\n"))
     (ignore-errors (hyprland-zen-stop))
     (kill-emacs 1))))

;;; hyprland-zen-live-runner.el ends here
