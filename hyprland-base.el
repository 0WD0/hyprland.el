;;; hyprland-base.el --- Core utilities for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Base customization and process helpers shared by hyprland modules.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup hyprland nil
  "Hyprland window integration for Emacs."
  :group 'tools)

(defcustom hyprland-debug nil
  "When non-nil, emit debug messages for hyprland.el internals."
  :type 'boolean
  :group 'hyprland)

(defcustom hyprland-hyprctl-executable "hyprctl"
  "Path to the hyprctl executable."
  :type 'string
  :group 'hyprland)

(defcustom hyprland-preview-sensitive-regexp nil
  "Regexp matching sensitive window titles/classes.

If non-nil and a window title/class matches this regexp, screenshot preview is
skipped and a textual placeholder is shown."
  :type '(choice (const :tag "Disabled" nil) regexp)
  :group 'hyprland)

(defcustom hyprland-preview-cache-mode 'memory-only
  "Preview cache mode.

`memory-only' keeps screenshot bytes in memory only.
`disk' writes cache files under `hyprland-preview-cache-directory'."
  :type '(choice (const :tag "Memory only" memory-only)
          (const :tag "Disk" disk))
  :group 'hyprland)

(defcustom hyprland-preview-cache-directory
  (expand-file-name "~/.cache/hyprland/previews/")
  "Directory for screenshot cache when `hyprland-preview-cache-mode' is `disk'."
  :type 'directory
  :group 'hyprland)

(defun hyprland--debug (fmt &rest args)
  "Emit debug message FMT with ARGS when `hyprland-debug' is non-nil."
  (when hyprland-debug
    (message "[hyprland] %s" (apply #'format fmt args))))

(defun hyprland--normalize-address (addr)
  "Normalize window ADDR to `0x...` lower-case format."
  (let ((raw (downcase (string-trim (format "%s" addr)))))
    (if (string-prefix-p "0x" raw)
        raw
      (concat "0x" raw))))

(defun hyprland--extract-hex-token (payload)
  "Extract first hex token from PAYLOAD and normalize as address.

Return nil if no token is found."
  (when (and (stringp payload)
             (string-match "\\`\\([0-9A-Fa-f]+\\)\\b" payload))
    (hyprland--normalize-address (match-string 1 payload))))

(defun hyprland--instance-signature ()
  "Return current Hyprland instance signature, or nil if absent."
  (getenv "HYPRLAND_INSTANCE_SIGNATURE"))

(defun hyprland--socket-path ()
  "Return absolute path to Hyprland socket2.

Signal a user error when required environment variables are missing."
  (let ((runtime (getenv "XDG_RUNTIME_DIR"))
        (sig (hyprland--instance-signature)))
    (unless (and runtime sig)
      (user-error "Missing XDG_RUNTIME_DIR or HYPRLAND_INSTANCE_SIGNATURE"))
    (expand-file-name (format "hypr/%s/.socket2.sock" sig) runtime)))

(defun hyprland--call-process-to-string (&rest args)
  "Run command ARGS and return stdout as string or signal on failure."
  (with-temp-buffer
    (let ((exit (apply #'process-file (car args) nil (current-buffer) nil (cdr args))))
      (if (zerop exit)
          (buffer-string)
        (error "%s failed (%s): %s" (car args) exit (string-trim (buffer-string)))))))

(defun hyprland--hyprctl-json (subcmd)
  "Run `hyprctl -j SUBCMD' and parse resulting JSON.

Return parsed Lisp object with JSON arrays as lists and objects as alists."
  (let* ((json-array-type 'list)
         (json-object-type 'alist)
         (json-false :false)
         (json-null nil)
         (raw (hyprland--call-process-to-string hyprland-hyprctl-executable "-j" subcmd)))
    (json-read-from-string raw)))

(defun hyprland--dispatch (dispatcher arg)
  "Run `hyprctl dispatch DISPATCHER ARG' and return stdout.

Errors are raised so callers can react and surface clear user feedback."
  (hyprland--call-process-to-string hyprland-hyprctl-executable "dispatch" dispatcher arg))

(provide 'hyprland-base)
;;; hyprland-base.el ends here
