;;; hyprland-reconcile.el --- Reconcile scheduler for hyprland.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Event streams are noisy and incomplete.  This scheduler coalesces reconcile
;; requests and enforces bounded refresh rates.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hyprland-base)

(defgroup hyprland-reconcile nil
  "Reconcile policy for hyprland.el."
  :group 'hyprland)

(defcustom hyprland-reconcile-debounce-ms 120
  "Debounce interval for coalescing near-simultaneous requests."
  :type 'integer
  :group 'hyprland-reconcile)

(defcustom hyprland-reconcile-fast-min-interval-ms 400
  "Minimum interval between two fast reconcile runs."
  :type 'integer
  :group 'hyprland-reconcile)

(defcustom hyprland-reconcile-fast-burst-limit 6
  "Maximum fast reconciles allowed in a burst window."
  :type 'integer
  :group 'hyprland-reconcile)

(defcustom hyprland-reconcile-fast-burst-window-ms 10000
  "Burst accounting window for `hyprland-reconcile-fast-burst-limit'."
  :type 'integer
  :group 'hyprland-reconcile)

(defcustom hyprland-reconcile-full-interval-ms 8000
  "Periodic full reconcile interval."
  :type 'integer
  :group 'hyprland-reconcile)

(defvar hyprland-reconcile-function nil
  "Reconcile callback called with one argument MODE (`fast' or `full').")

(defvar hyprland-reconcile--debounce-timer nil)
(defvar hyprland-reconcile--periodic-timer nil)
(defvar hyprland-reconcile--pending-mode nil)
(defvar hyprland-reconcile--running nil)
(defvar hyprland-reconcile--pending-after-run nil)
(defvar hyprland-reconcile--last-fast-ts 0.0)
(defvar hyprland-reconcile--fast-burst-ts nil)

(defun hyprland-reconcile--now ()
  "Return current monotonic time in seconds as float."
  (float-time))

(defun hyprland-reconcile--prefer-mode (old new)
  "Return stronger mode between OLD and NEW.

`full' dominates `fast'."
  (cond
   ((eq old 'full) 'full)
   ((eq new 'full) 'full)
   ((or (eq old 'fast) (eq new 'fast)) 'fast)
   (t nil)))

(defun hyprland-reconcile--prune-burst (now)
  "Drop burst timestamps older than burst window relative to NOW."
  (let ((cutoff (- now (/ hyprland-reconcile-fast-burst-window-ms 1000.0))))
    (setq hyprland-reconcile--fast-burst-ts
          (cl-remove-if (lambda (ts) (< ts cutoff)) hyprland-reconcile--fast-burst-ts))))

(defun hyprland-reconcile--fast-allowed-p ()
  "Return non-nil if a fast reconcile is allowed at current time.

This enforces min-interval and burst limits."
  (let ((now (hyprland-reconcile--now)))
    (hyprland-reconcile--prune-burst now)
    (and (>= (- now hyprland-reconcile--last-fast-ts)
             (/ hyprland-reconcile-fast-min-interval-ms 1000.0))
         (< (length hyprland-reconcile--fast-burst-ts)
            hyprland-reconcile-fast-burst-limit))))

(defun hyprland-reconcile--note-fast-run ()
  "Record accounting for a fast reconcile run."
  (let ((now (hyprland-reconcile--now)))
    (setq hyprland-reconcile--last-fast-ts now)
    (push now hyprland-reconcile--fast-burst-ts)
    (hyprland-reconcile--prune-burst now)))

(defun hyprland-reconcile--run (mode)
  "Run reconcile callback with MODE, respecting in-flight coalescing."
  (let* ((effective-mode (if (and (eq mode 'fast)
                                  (not (hyprland-reconcile--fast-allowed-p)))
                             'full
                           mode)))
    (if hyprland-reconcile--running
        (setq hyprland-reconcile--pending-after-run
              (hyprland-reconcile--prefer-mode hyprland-reconcile--pending-after-run effective-mode))
      (setq hyprland-reconcile--running t)
      (unwind-protect
          (progn
            (when (eq effective-mode 'fast)
              (hyprland-reconcile--note-fast-run))
            (when hyprland-reconcile-function
              (funcall hyprland-reconcile-function effective-mode)))
        (setq hyprland-reconcile--running nil)
        (when hyprland-reconcile--pending-after-run
          (let ((pending hyprland-reconcile--pending-after-run))
            (setq hyprland-reconcile--pending-after-run nil)
            (hyprland-reconcile-request pending "pending-after-run")))))))

(defun hyprland-reconcile--flush-debounced ()
  "Execute and clear the pending debounced request."
  (let ((mode hyprland-reconcile--pending-mode))
    (setq hyprland-reconcile--debounce-timer nil
          hyprland-reconcile--pending-mode nil)
    (when mode
      (hyprland--debug "reconcile flush mode=%s" mode)
      (hyprland-reconcile--run mode))))

(defun hyprland-reconcile-request (mode &optional reason)
  "Request reconcile MODE (`fast' or `full'), coalesced by debounce.

REASON is optional debug context."
  (setq hyprland-reconcile--pending-mode
        (hyprland-reconcile--prefer-mode hyprland-reconcile--pending-mode mode))
  (hyprland--debug "reconcile request mode=%s reason=%s" mode reason)
  (unless hyprland-reconcile--debounce-timer
    (setq hyprland-reconcile--debounce-timer
          (run-at-time
           0
           (/ hyprland-reconcile-debounce-ms 1000.0)
           #'hyprland-reconcile--flush-debounced))))

(defun hyprland-reconcile-request-fast (&optional reason)
  "Request a fast reconcile with optional REASON."
  (hyprland-reconcile-request 'fast reason))

(defun hyprland-reconcile-request-full (&optional reason)
  "Request a full reconcile with optional REASON."
  (hyprland-reconcile-request 'full reason))

(defun hyprland-reconcile-start ()
  "Start periodic full reconcile timer."
  (hyprland-reconcile-stop)
  (setq hyprland-reconcile--periodic-timer
        (run-at-time
         0
         (/ hyprland-reconcile-full-interval-ms 1000.0)
         (lambda ()
           (hyprland-reconcile-request-full "periodic")))))

(defun hyprland-reconcile-stop ()
  "Stop all reconcile timers and in-flight debounce state."
  (when (timerp hyprland-reconcile--debounce-timer)
    (cancel-timer hyprland-reconcile--debounce-timer))
  (when (timerp hyprland-reconcile--periodic-timer)
    (cancel-timer hyprland-reconcile--periodic-timer))
  (setq hyprland-reconcile--debounce-timer nil
        hyprland-reconcile--periodic-timer nil
        hyprland-reconcile--pending-mode nil
        hyprland-reconcile--pending-after-run nil))

(provide 'hyprland-reconcile)
;;; hyprland-reconcile.el ends here
