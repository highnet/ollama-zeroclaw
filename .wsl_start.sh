#!/usr/bin/env bash
set -euo pipefail

# Starter script to be executed inside WSL from Windows Terminal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_WSL_PATH="$SCRIPT_DIR"
cd "$REPO_WSL_PATH"

# Ensure env and tools are available
source "$HOME/.cargo/env" 2>/dev/null || true
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Stop any existing zeroclaw/ollama
pkill -f zeroclaw || true
pkill -f ollama || true
sleep 1

# Run setup (starts Ollama, pulls model, starts daemon, patches config)
./scripts/wsl/setup.sh || true

# Launch interactive control TUI
exec python3.12 ./scripts/wsl/control_tui.py
