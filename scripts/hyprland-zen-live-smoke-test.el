;;; hyprland-zen-live-smoke-test.el --- Live Zen bridge smoke test -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime smoke test for real Zen bridge data path.
;; This script is intentionally not part of ERT.

;;; Code:

(require 'cl-lib)
(require 'hyprland-zen)

(defun hyprland-zen-live-smoke--fail (fmt &rest args)
  "Signal fatal smoke-test error using FMT and ARGS."
  (error "[hyprland-zen-live] %s" (apply #'format fmt args)))

(defun hyprland-zen-live-smoke--assert (pred fmt &rest args)
  "Assert PRED, otherwise fail with FMT and ARGS."
  (unless pred
    (apply #'hyprland-zen-live-smoke--fail fmt args)))

(defun hyprland-zen-live-smoke--wait (predicate timeout)
  "Wait up to TIMEOUT seconds until PREDICATE returns non-nil."
  (let ((deadline (+ (float-time) timeout))
        out)
    (while (and (not (setq out (funcall predicate)))
                (< (float-time) deadline))
      (when (hyprland-zen-running-p)
        (accept-process-output hyprland-zen--process 0.2)))
    out))

(defun hyprland-zen-live-smoke-run ()
  "Run live smoke test for Zen tab list, preview request, and tab activation."
  (let* ((timeout 10.0)
         (hyprland-zen-jump-to-window-on-tab-switch nil)
         doctor tabs tab tab-id preview-ts-before activated-key status)
    (ignore-errors (hyprland-zen-stop))
    (hyprland-zen-start)
    (hyprland-zen-trace-reset)
    (setq doctor (hyprland-zen-doctor timeout)
          tabs (hyprland-zen-tabs))

    (hyprland-zen-live-smoke--assert (plist-get doctor :running)
                                     "bridge is not running after doctor: %S"
                                     doctor)
    (hyprland-zen-live-smoke--assert tabs
                                     "tabs list is empty after doctor: %S"
                                     (hyprland-zen-status))

    (setq tab (or (cl-find-if (lambda (it)
                                (hyprland-zen--truthy-p (hyprland-zen--field it 'active)))
                              tabs)
                  (car tabs))
          tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id)))
    (hyprland-zen-live-smoke--assert (not (string-empty-p tab-id))
                                     "selected tab has empty tab_id: %S"
                                     tab)

    ;; Batch smoke should verify preview protocol readiness without requiring GUI image rendering.
    (cl-letf (((symbol-function 'hyprland-zen--display-preview-data-url)
               (lambda (_data-url) t))
              ((symbol-function 'hyprland-zen--display-preview-message)
               (lambda (_message) nil)))
      (setq hyprland-zen--preview-tab-id tab-id
            preview-ts-before hyprland-zen--last-preview-response-at)
      (hyprland-zen--send `((op . "capture-tab") (tab_id . ,tab-id)))
      (hyprland-zen-live-smoke--assert
       (hyprland-zen-live-smoke--wait
        (lambda ()
          (and hyprland-zen--last-preview-response-at
               (or (null preview-ts-before)
                   (> hyprland-zen--last-preview-response-at preview-ts-before))))
        timeout)
       "capture-tab did not yield preview response; status=%S"
       (hyprland-zen-status)))

    (setq activated-key (hyprland-zen-tab-switch tab))
    (hyprland-zen-live-smoke--assert activated-key
                                     "tab activation did not return key")

    (setq status (hyprland-zen-status))
    (hyprland-zen-live-smoke--assert
     (not (member (plist-get status :last-error-op)
                  '("activate-tab" "capture-tab")))
     "operation reported error: %S"
     status)

    (princ (format "[hyprland-zen-live] OK tabs=%d workspaces=%d trace=%d\n"
                   (plist-get status :tab-count)
                   (plist-get status :workspace-count)
                   (plist-get status :trace-count)))))

(defvar hyprland-zen-live-smoke-auto-run t
  "When non-nil, run live smoke test immediately on file load.")

(when hyprland-zen-live-smoke-auto-run
  (hyprland-zen-live-smoke-run))

;;; hyprland-zen-live-smoke-test.el ends here
