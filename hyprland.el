;;; hyprland.el --- Hyprland integration for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0

;; Author: 0WD0 <wd.1105848296@gmail.com>
;; Maintainer: 0WD0 <wd.1105848296@gmail.com>
;; Keywords: tools, wayland
;; URL: https://github.com/0wd0/hyprland.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (consult "1.4"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Window-level integration with Hyprland:
;; - Snapshot + socket2 sync
;; - Reconcile policy with bounded refresh rates
;; - Consult-powered window switch with static preview

;;; Code:

(require 'hyprland-base)
(require 'hyprland-reconcile)
(require 'hyprland-sync)
(require 'hyprland-preview)
(require 'hyprland-consult)
(require 'hyprland-ibuffer)

(provide 'hyprland)
;;; hyprland.el ends here
