#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if ! command -v eask >/dev/null 2>&1; then
	echo "[hyprland-zen-test] eask is required but not found in PATH" >&2
	exit 127
fi

MODE="${1:-all}"

reset_line_bridge_if_enabled() {
	if [[ "${HYPRLAND_ZEN_TEST_RESET_HOST:-1}" != "0" ]]; then
		pkill -f "hyprland-zen-native-host --line-stdio" >/dev/null 2>&1 || true
		sleep 0.2
	fi
}

run_unit() {
	echo "[hyprland-zen-test] running unit tests (test/hyprland-zen-test.el)"
	eask emacs --batch -Q --eval "(setq load-prefer-newer t)" -L . -l test/hyprland-zen-test.el -f ert-run-tests-batch-and-exit
}

run_doctor() {
	echo "[hyprland-zen-test] running runtime doctor (non-interactive)"
	reset_line_bridge_if_enabled
	eask emacs --batch -Q --eval "(setq load-prefer-newer t)" -L . -l hyprland.el -l scripts/hyprland-zen-check.el
}

run_live() {
	echo "[hyprland-zen-test] running live smoke test (requires Zen extension + native host)"
	reset_line_bridge_if_enabled
	eask emacs --batch -Q --eval "(setq load-prefer-newer t)" -L . -l hyprland.el -l scripts/hyprland-zen-live-runner.el
}

run_all() {
	local failed=0

	run_unit || failed=1
	run_doctor || failed=1
	run_live || failed=1

	if [[ "${failed}" -ne 0 ]]; then
		echo "[hyprland-zen-test] completed with failures" >&2
		return 1
	fi

	echo "[hyprland-zen-test] all checks passed"
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
  HYPRLAND_ZEN_TEST_RESET_HOST=0  Keep existing line-stdio host (default resets)
EOF
}

cd "${ROOT_DIR}"

case "${MODE}" in
all)
	run_all
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
