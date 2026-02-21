;;; hyprland-sync.el --- Hyprland sync engine -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Snapshot + event-stream synchronization for Hyprland windows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)
(require 'hyprland-reconcile)

(defvar hyprland-sync--windows (make-hash-table :test #'equal)
  "Window store keyed by normalized address (0x...).")

(defvar hyprland-sync--socket-process nil)
(defvar hyprland-sync--socket-fragment "")
(defvar hyprland-sync--started nil)

(defvar hyprland-after-refresh-hook nil
  "Hook run after `hyprland-refresh' replaces the in-memory window store.")

(defconst hyprland-sync--address-events
  '(openwindow closewindow windowtitlev2 movewindowv2 changefloatingmode pin)
  "Events carrying a directly parseable address token.")

(defconst hyprland-sync--global-reconcile-events
  '(fullscreen focusedmonv2 workspacev2 monitoraddedv2 monitorremovedv2)
  "Events that should trigger full reconcile without single-window updates.")

(defun hyprland-sync--clear-store ()
  "Clear in-memory window store."
  (clrhash hyprland-sync--windows))

(defun hyprland-sync--window-address (window)
  "Return normalized address for WINDOW alist."
  (when-let* ((raw (alist-get 'address window)))
    (hyprland--normalize-address raw)))

(defun hyprland-sync--store-window (window)
  "Store WINDOW object in hash table, keyed by normalized address."
  (when-let* ((address (hyprland-sync--window-address window)))
    (puthash address window hyprland-sync--windows)))

(defun hyprland-windows ()
  "Return current window list from in-memory store."
  (let (out)
    (maphash (lambda (_k v) (push v out)) hyprland-sync--windows)
    (nreverse out)))

(defun hyprland-window-get (address)
  "Return window record for ADDRESS, or nil."
  (gethash (hyprland--normalize-address address) hyprland-sync--windows))

(defun hyprland--clients-json ()
  "Return `hyprctl -j clients' parsed payload."
  (hyprland--hyprctl-json "clients"))

(defun hyprland-refresh ()
  "Run full clients snapshot and replace in-memory window store."
  (interactive)
  (let ((windows (hyprland--clients-json)))
    (hyprland-sync--clear-store)
    (dolist (w windows)
      (hyprland-sync--store-window w))
    (hyprland--debug "snapshot windows=%d" (hash-table-count hyprland-sync--windows))
    (run-hooks 'hyprland-after-refresh-hook)))

(defun hyprland-sync--split-event-line (line)
  "Parse socket LINE into (:name event-symbol :payload raw-data).

Return nil when format does not match EVENT>>DATA.
Unknown events are still returned, allowing policy-based handling upstream."
  (when (and (stringp line)
             (string-match "\\`\\([^>]+\\)>>\\(.*\\)\\'" line))
    (let* ((event-name (downcase (match-string 1 line)))
           (payload (match-string 2 line)))
      (list :name (intern event-name)
            :payload payload
            :raw line))))

(defun hyprland-sync--process-event (event)
  "Handle parsed EVENT plist from socket stream."
  (let* ((name (plist-get event :name))
         (payload (plist-get event :payload)))
    (cond
     ((memq name hyprland-sync--address-events)
      (if-let* ((addr (hyprland--extract-hex-token payload)))
          (progn
            (when (eq name 'closewindow)
              (remhash addr hyprland-sync--windows))
            ;; We intentionally avoid hard-updating non-trivial fields from
            ;; payload strings and converge with fast reconcile.
            (hyprland-reconcile-request-fast (symbol-name name)))
        (hyprland-reconcile-request-full (format "parse-failed:%s" name))))
     ((memq name hyprland-sync--global-reconcile-events)
      (hyprland-reconcile-request-full (symbol-name name)))
     (t
      nil))))

(defun hyprland-sync--socket-filter (_proc chunk)
  "Socket filter that parses CHUNK as line-oriented event stream."
  (setq hyprland-sync--socket-fragment (concat hyprland-sync--socket-fragment chunk))
  (let ((start 0)
        line)
    (while (string-match "\n" hyprland-sync--socket-fragment start)
      (setq line (substring hyprland-sync--socket-fragment start (match-beginning 0)))
      (setq start (match-end 0))
      (when-let* ((event (hyprland-sync--split-event-line line)))
        (hyprland-sync--process-event event)))
    (setq hyprland-sync--socket-fragment
          (substring hyprland-sync--socket-fragment start))))

(defun hyprland-sync--socket-sentinel (_proc event)
  "Handle socket EVENT and schedule reconnect + full reconcile."
  (hyprland--debug "socket sentinel: %s" (string-trim event))
  (when hyprland-sync--started
    (run-at-time
     1 nil
     (lambda ()
       (ignore-errors
         (hyprland-sync--open-socket)
         (hyprland-reconcile-request-full "socket-reconnect"))))))

(defun hyprland-sync--open-socket ()
  "Open Hyprland socket2 listener process."
  (when (process-live-p hyprland-sync--socket-process)
    (delete-process hyprland-sync--socket-process))
  (setq hyprland-sync--socket-fragment "")
  (setq hyprland-sync--socket-process
        (make-network-process
         :name "hyprland-socket2"
         :family 'local
         :service (hyprland--socket-path)
         :coding 'utf-8-unix
         :filter #'hyprland-sync--socket-filter
         :sentinel #'hyprland-sync--socket-sentinel)))

(defun hyprland-sync-start ()
  "Start Hyprland sync engine (snapshot + socket + periodic reconcile)."
  (interactive)
  (setq hyprland-sync--started t)
  (setq hyprland-reconcile-function
        (lambda (_mode)
          (hyprland-refresh)))
  (hyprland-refresh)
  (hyprland-sync--open-socket)
  (hyprland-reconcile-start)
  (hyprland-reconcile-request-full "sync-start"))

(defun hyprland-sync-stop ()
  "Stop Hyprland sync engine and timers."
  (interactive)
  (setq hyprland-sync--started nil)
  (hyprland-reconcile-stop)
  (when (process-live-p hyprland-sync--socket-process)
    (delete-process hyprland-sync--socket-process))
  (setq hyprland-sync--socket-process nil
        hyprland-sync--socket-fragment ""))

(defun hyprland-jump (address)
  "Focus Hyprland window by ADDRESS."
  (interactive (list (completing-read "Address: " (hash-table-keys hyprland-sync--windows) nil t)))
  (hyprland--dispatch "focuswindow" (format "address:%s" (hyprland--normalize-address address))))

(defun hyprland-close (address)
  "Close Hyprland window by ADDRESS."
  (interactive (list (completing-read "Address: " (hash-table-keys hyprland-sync--windows) nil t)))
  (hyprland--dispatch "closewindow" (format "address:%s" (hyprland--normalize-address address))))

(defun hyprland-tag (address tag-op)
  "Apply TAG-OP to window ADDRESS using `tagwindow` dispatcher.

TAG-OP accepts +foo, -foo, or foo(toggle)."
  (interactive
   (list (completing-read "Address: " (hash-table-keys hyprland-sync--windows) nil t)
         (read-string "Tag op (+foo/-foo/foo): ")))
  (hyprland--dispatch "tagwindow"
                      (format "%s address:%s" tag-op (hyprland--normalize-address address)))
  (hyprland-reconcile-request-fast "tag-command"))

(provide 'hyprland-sync)
;;; hyprland-sync.el ends here
