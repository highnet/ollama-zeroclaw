#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Prefer python3.12 if python3 is not in PATH
PYTHON="$(command -v python3 2>/dev/null || command -v python3.12 2>/dev/null || echo python3.12)"

# Ensure ~/.local/bin is on PATH (for textual installed via pip --user)
export PATH="$HOME/.local/bin:$PATH"

require_cmd ollama
require_cmd zeroclaw

# Ensure zeroclaw config is patched (port, pairing, sandbox)
"$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true

mkdir -p "$RUNTIME_DIR"

exec "$PYTHON" "$SCRIPT_DIR/control_tui.py"