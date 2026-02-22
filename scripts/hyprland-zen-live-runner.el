;;; hyprland-zen-live-runner.el --- Friendly runner for Zen live smoke test -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run live smoke test with concise failure output for CI/troubleshooting.

;;; Code:

(setq debug-on-error nil)
(setq debug-early-backtrace nil)

(defun hyprland-zen-live-runner--trim-string (s &optional max-len)
  "Return S trimmed to MAX-LEN characters with ellipsis when needed."
  (let* ((raw (if (stringp s) s (format "%s" s)))
         (limit (or max-len 140)))
    (if (> (length raw) limit)
        (concat (substring raw 0 limit) "...")
      raw)))

(defun hyprland-zen-live-runner--payload-summary (payload)
  "Return compact summary string for one bridge PAYLOAD."
  (cond
   ((not (listp payload))
    (hyprland-zen-live-runner--trim-string payload 120))
   (t
    (let* ((type (hyprland-zen--string (hyprland-zen--field payload 'type)))
           (op (hyprland-zen--string (hyprland-zen--field payload 'op)))
           (tabs (hyprland-zen--field payload 'tabs))
           (workspaces (hyprland-zen--field payload 'workspaces))
           (tab-id (hyprland-zen--field payload 'tab_id))
           (key (hyprland-zen--field payload 'key))
           (msg (hyprland-zen--field payload 'message))
           parts)
      (when (not (string-empty-p type))
        (push (format "type=%s" type) parts))
      (when (not (string-empty-p op))
        (push (format "op=%s" op) parts))
      (when (listp tabs)
        (push (format "tabs=%d" (length tabs)) parts))
      (when (listp workspaces)
        (push (format "workspaces=%d" (length workspaces)) parts))
      (when tab-id
        (push (format "tab_id=%s" tab-id) parts))
      (when key
        (push (format "key=%s" key) parts))
      (when msg
        (push (format "message=%s" (hyprland-zen-live-runner--trim-string msg 90)) parts))
      (if parts
          (mapconcat #'identity (nreverse parts) " ")
        "payload=<unrecognized>")))))

(defun hyprland-zen-live-runner--print-trace-summary (&optional limit)
  "Print compact summary of recent bridge trace entries up to LIMIT."
  (let* ((n (max 1 (or limit 16)))
         (entries (cl-subseq hyprland-zen--trace 0 (min n (length hyprland-zen--trace)))))
    (princ "[hyprland-zen-live-runner] trace-summary-begin\n")
    (if (null entries)
        (princ "[hyprland-zen-live-runner] trace=<empty>\n")
      (dolist (entry entries)
        (let* ((ts (or (plist-get entry :ts) 0.0))
               (dir (or (plist-get entry :dir) "?"))
               (payload (plist-get entry :payload))
               (summary (hyprland-zen-live-runner--payload-summary payload)))
          (princ (format "[hyprland-zen-live-runner] trace ts=%s dir=%s %s\n"
                         (format-time-string "%F %T" (seconds-to-time ts))
                         dir
                         summary)))))
    (princ "[hyprland-zen-live-runner] trace-summary-end\n")))

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
       (princ (format "[hyprland-zen-live-runner] status running=%s tabs=%s workspaces=%s in/out=%s/%s last-error-op=%s last-error=%s\n"
                      (plist-get status :running)
                      (plist-get status :tab-count)
                      (plist-get status :workspace-count)
                      (plist-get status :messages-in)
                      (plist-get status :messages-out)
                      (or (plist-get status :last-error-op) "")
                      (or (plist-get status :last-error-message) ""))))
     (hyprland-zen-live-runner--print-trace-summary 16)
     (ignore-errors (hyprland-zen-stop))
     (kill-emacs 1))))

;;; hyprland-zen-live-runner.el ends here
