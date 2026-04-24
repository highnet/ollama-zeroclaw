#!/bin/bash
# Wrapper called by wt.exe. Runs the TUI launcher, then keeps the tab open.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/launch.sh"
exec bash -l
