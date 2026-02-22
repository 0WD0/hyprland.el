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

(defun hyprland-zen-live-smoke--capturable-url-p (url)
  "Return non-nil when URL is likely capturable for screenshot preview checks."
  (and (stringp url)
       (or (string-prefix-p "http://" url)
           (string-prefix-p "https://" url)
           (string-prefix-p "file://" url))))

(defun hyprland-zen-live-smoke--discarded-p (tab)
  "Return non-nil when TAB is currently discarded/unloaded."
  (hyprland-zen--truthy-p (hyprland-zen--field tab 'discarded)))

(defun hyprland-zen-live-smoke--pick-tab (tabs)
  "Pick best smoke-test TAB from TABS list.

Prefer active + capturable URL, then any capturable, then active, then first." 
  (or (cl-find-if (lambda (it)
                    (and (hyprland-zen--truthy-p (hyprland-zen--field it 'active))
                         (not (hyprland-zen-live-smoke--discarded-p it))
                         (hyprland-zen-live-smoke--capturable-url-p
                          (hyprland-zen--string (hyprland-zen--field it 'url)))))
                  tabs)
      (cl-find-if (lambda (it)
                    (and (not (hyprland-zen-live-smoke--discarded-p it))
                         (hyprland-zen-live-smoke--capturable-url-p
                          (hyprland-zen--string (hyprland-zen--field it 'url)))))
                  tabs)
      (cl-find-if (lambda (it)
                    (and (hyprland-zen--truthy-p (hyprland-zen--field it 'active))
                         (not (hyprland-zen-live-smoke--discarded-p it))))
                  tabs)
      (cl-find-if (lambda (it)
                    (not (hyprland-zen-live-smoke--discarded-p it)))
                  tabs)
      (car tabs)))

(defun hyprland-zen-live-smoke--find-tab-by-url-prefix (prefix)
  "Find first tab whose URL starts with PREFIX."
  (cl-find-if (lambda (entry)
                (string-prefix-p prefix (hyprland-zen--string (hyprland-zen--field entry 'url))))
              (hyprland-zen-tabs)))

(defun hyprland-zen-live-smoke--request-preview (tab-id timeout)
  "Request preview for TAB-ID and wait up to TIMEOUT seconds.

Returns one of symbols: ok, error, timeout."
  (let ((preview-ts-before hyprland-zen--last-preview-response-at))
    (setq hyprland-zen--preview-tab-id tab-id)
    (hyprland-zen--send `((op . "capture-tab") (tab_id . ,tab-id)))
    (if (hyprland-zen-live-smoke--wait
         (lambda ()
           (or (and hyprland-zen--last-preview-response-at
                    (or (null preview-ts-before)
                        (> hyprland-zen--last-preview-response-at preview-ts-before)))
               (string= hyprland-zen--last-error-op "capture-tab")))
         timeout)
        (if (string= hyprland-zen--last-error-op "capture-tab")
            'error
          'ok)
      'timeout)))

(defun hyprland-zen-live-smoke-run ()
  "Run live smoke test for Zen tab list, preview request, and tab activation."
  (let* ((timeout 10.0)
         (hyprland-zen-jump-to-window-on-tab-switch nil)
         doctor tabs tab tab-id activated-key status preview-result probe-url)
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

    (setq tab (hyprland-zen-live-smoke--pick-tab tabs)
          tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id)))
    (hyprland-zen-live-smoke--assert (not (string-empty-p tab-id))
                                     "selected tab has empty tab_id: %S"
                                     tab)
    (princ (format "[hyprland-zen-live] selected tab id=%s active=%s discarded=%s url=%s\n"
                   tab-id
                   (hyprland-zen--field tab 'active)
                   (hyprland-zen--field tab 'discarded)
                   (hyprland-zen--string (hyprland-zen--field tab 'url))))

    (unless (hyprland-zen--truthy-p (hyprland-zen--field tab 'active))
      (hyprland-zen-tab-switch tab)
      (hyprland-zen-live-smoke--assert
       (hyprland-zen-live-smoke--wait
        (lambda ()
          (when-let* ((it (cl-find-if (lambda (entry)
                                        (string= (hyprland-zen--string (hyprland-zen--field entry 'tab_id))
                                                 tab-id))
                                      (hyprland-zen-tabs))))
            (hyprland-zen--truthy-p (hyprland-zen--field it 'active))))
        timeout)
       "failed to activate candidate tab before capture: %S"
       (hyprland-zen-status)))

    (if (hyprland-zen-live-smoke--capturable-url-p
         (hyprland-zen--string (hyprland-zen--field tab 'url)))
        (cl-letf (((symbol-function 'hyprland-zen--display-preview-data-url)
                   (lambda (_data-url) t))
                  ((symbol-function 'hyprland-zen--display-preview-message)
                   (lambda (_message) nil)))
          (setq preview-result (hyprland-zen-live-smoke--request-preview tab-id timeout))
          (when (eq preview-result 'timeout)
            (setq probe-url (format "https://example.com/?hyprland-zen-smoke=%s"
                                    (format-time-string "%s")))
            (princ (format "[hyprland-zen-live] retry preview via fresh tab: %s\n" probe-url))
            (hyprland-zen--send `((op . "open-url") (url . ,probe-url)))
            (setq tab
                  (hyprland-zen-live-smoke--wait
                   (lambda ()
                     (hyprland-zen-live-smoke--find-tab-by-url-prefix probe-url))
                   timeout))
            (when (and (null tab)
                       (string= (or hyprland-zen--last-error-op "") "open-url")
                       (string-match-p "browser-bridge-" (or hyprland-zen--last-error-message "")))
              (princ "[hyprland-zen-live] open-url lost during reconnect, retrying once\n")
              (hyprland-zen--send `((op . "open-url") (url . ,probe-url)))
              (setq tab
                    (hyprland-zen-live-smoke--wait
                     (lambda ()
                       (hyprland-zen-live-smoke--find-tab-by-url-prefix probe-url))
                     timeout)))
            (hyprland-zen-live-smoke--assert tab
                                             "open-url probe tab did not appear; status=%S"
                                             (hyprland-zen-status))
            (setq tab-id (hyprland-zen--string (hyprland-zen--field tab 'tab_id)))
            (setq preview-result (hyprland-zen-live-smoke--request-preview tab-id timeout)))
          (pcase preview-result
            ('ok nil)
            ('error
             (hyprland-zen-live-smoke--fail
              "capture-tab reported error: %S"
              (hyprland-zen-status)))
            (_
             (hyprland-zen-live-smoke--fail
              "capture-tab did not complete; status=%S"
              (hyprland-zen-status)))))
      (princ (format "[hyprland-zen-live] skip preview check for non-capturable url: %s\n"
                     (hyprland-zen--string (hyprland-zen--field tab 'url)))))

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
