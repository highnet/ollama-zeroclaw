#!/bin/bash
# Wrapper called by wt.exe. Runs the TUI launcher, then keeps the tab open.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
set +e
bash "$SCRIPT_DIR/launch.sh"
launch_status=$?
set -e

if [[ "$launch_status" -ne 0 ]]; then
	echo
	echo "Launcher exited with code $launch_status"
fi

exec bash -li
