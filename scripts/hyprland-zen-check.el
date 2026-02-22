;;; hyprland-zen-check.el --- Batch diagnostics for Zen bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Non-interactive diagnostics for hyprland-zen runtime readiness.
;; Exit code 0 means tabs/workspaces are ready; non-zero means the bridge is
;; misconfigured or not connected to the browser extension yet.

;;; Code:

(require 'cl-lib)
(require 'hyprland-zen)

(defconst hyprland-zen-check--default-timeout 6.0
  "Default wait time for `hyprland-zen-doctor' in batch mode.")

(defun hyprland-zen-check--env-timeout ()
  "Read timeout from HYPRLAND_ZEN_CHECK_TIMEOUT, or fallback default."
  (let ((raw (getenv "HYPRLAND_ZEN_CHECK_TIMEOUT")))
    (if (and raw (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" raw))
        (string-to-number raw)
      hyprland-zen-check--default-timeout)))

(defun hyprland-zen-check--print-kv (key value)
  "Print one KEY/VALUE status line."
  (princ (format "[hyprland-zen-check] %s=%s\n" key value)))

(defun hyprland-zen-check--print-hints (status)
  "Print actionable hints using bridge STATUS plist."
  (let ((msg (or (plist-get status :last-error-message) "")))
    (cond
     ((string-match-p "browser-bridge-not-connected" msg)
      (princ "[hyprland-zen-check] hint: Browser extension is not connected to Native Messaging host.\n")
      (princ "[hyprland-zen-check] hint: Open Browser Toolbox and verify extension logs from browser/zen-extension/background.js.\n")
      (princ "[hyprland-zen-check] hint: Verify native host manifest path in browser/native-host/hyprland_zen_bridge.json.\n"))
     ((string-match-p "browser-bridge-disconnected" msg)
      (princ "[hyprland-zen-check] hint: Browser bridge disconnected. Check extension reloads, payload-size errors, and native host logs.\n"))
     ((string-match-p "native-message-too-large" msg)
      (princ "[hyprland-zen-check] hint: Preview payload exceeded native message limits; retry with fewer/lighter tabs and check extension compression.\n"))
     ((string-match-p "Unable to resolve" msg)
      (princ "[hyprland-zen-check] hint: Set `hyprland-zen-host-command` to absolute native-host path.\n"))
     (t
      (princ "[hyprland-zen-check] hint: Run M-x hyprland-zen-trace-report for protocol details.\n")))))

(defun hyprland-zen-check-run ()
  "Run batch diagnostics and exit Emacs with pass/fail code."
  (let* ((timeout (hyprland-zen-check--env-timeout))
         (report nil)
         (status nil)
         (fatal nil)
         (exit-code 1))
    (let ((hyprland-zen-error-notify-throttle-seconds 3600.0)
          (inhibit-message t)
          (message-log-max nil))
      (condition-case err
          (progn
            (ignore-errors (hyprland-zen-stop))
            (hyprland-zen-start)
            (setq report (hyprland-zen-doctor timeout))
            (setq status (hyprland-zen-status)))
        (error
         (setq fatal (error-message-string err))
         (setq status (ignore-errors (hyprland-zen-status))))))

    (hyprland-zen-check--print-kv "timeout" timeout)
    (if fatal
        (progn
          (hyprland-zen-check--print-kv "fatal" fatal)
          (when (string-match-p "Unable to resolve" fatal)
            (princ "[hyprland-zen-check] hint: install browser/native-host/hyprland-zen-native-host or set hyprland-zen-host-command.\n")))
      (progn
        (hyprland-zen-check--print-kv "running" (if (plist-get report :running) "yes" "no"))
        (hyprland-zen-check--print-kv "tabs-ready" (plist-get report :tabs-ready))
        (hyprland-zen-check--print-kv "workspaces-ready" (plist-get report :workspaces-ready))))

    (when status
      (hyprland-zen-check--print-kv "tab-count" (plist-get status :tab-count))
      (hyprland-zen-check--print-kv "workspace-count" (plist-get status :workspace-count))
      (hyprland-zen-check--print-kv "messages-in" (plist-get status :messages-in))
      (hyprland-zen-check--print-kv "messages-out" (plist-get status :messages-out))
      (hyprland-zen-check--print-kv "last-error-op" (or (plist-get status :last-error-op) ""))
      (hyprland-zen-check--print-kv "last-error-message" (or (plist-get status :last-error-message) "")))

    (when status
      (hyprland-zen-check--print-hints status)
      (when-let* ((buf (ignore-errors (hyprland-zen-trace-report 12))))
        (princ "[hyprland-zen-check] trace-begin\n")
        (with-current-buffer buf
          (princ (buffer-substring-no-properties (point-min) (point-max))))
        (princ "[hyprland-zen-check] trace-end\n")))

    (setq exit-code
          (if (and (not fatal)
                   report
                   (plist-get report :running)
                   (plist-get report :tabs-ready)
                   (plist-get report :workspaces-ready))
              0
            1))

    (ignore-errors (hyprland-zen-stop))
    (kill-emacs exit-code)))

(hyprland-zen-check-run)

;;; hyprland-zen-check.el ends here
