#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if ! command -v eask >/dev/null 2>&1; then
	echo "[hyprland-zen-test] eask is required but not found in PATH" >&2
	exit 127
fi

MODE="${1:-all}"

run_unit() {
	echo "[hyprland-zen-test] running unit tests (test/hyprland-zen-test.el)"
	eask test ert test/hyprland-zen-test.el
}

run_doctor() {
	echo "[hyprland-zen-test] running runtime doctor (non-interactive)"
	eask emacs --batch -Q -l hyprland.el -l scripts/hyprland-zen-check.el
}

run_live() {
	echo "[hyprland-zen-test] running live smoke test (requires Zen extension + native host)"
	eask emacs --batch -Q -l hyprland.el -l scripts/hyprland-zen-live-smoke-test.el
}

usage() {
	cat <<'EOF'
Usage: scripts/hyprland-zen-test.sh [all|unit|doctor|live]

  all    Run unit + doctor + live smoke (default)
  unit   Run deterministic ERT tests only
  doctor Run bridge readiness diagnostics only
  live   Run live end-to-end smoke only

Environment:
  HYPRLAND_ZEN_CHECK_TIMEOUT=8.0  Override doctor timeout (seconds)
EOF
}

cd "${ROOT_DIR}"

case "${MODE}" in
all)
	run_unit
	run_doctor
	run_live
	;;
unit)
	run_unit
	;;
doctor)
	run_doctor
	;;
live)
	run_live
	;;
-h | --help | help)
	usage
	;;
*)
	echo "[hyprland-zen-test] unknown mode: ${MODE}" >&2
	usage
	exit 2
	;;
esac
