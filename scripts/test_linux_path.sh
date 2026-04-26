#!/usr/bin/env bash
source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LINUX_HOME="$HOME/.zeroclaw-repo"
mkdir -p "$LINUX_HOME"

# Copy config from Windows-mounted dir to Linux native dir
cp "$REPO_ROOT/.zeroclaw-home/config.toml" "$LINUX_HOME/"

# Onboard to create workspace files  
timeout 10 zeroclaw onboard --quick --force --provider ollama --model qwen2.5:1.5b --config-dir "$LINUX_HOME" 2>&1 | tail -5

echo ""
echo "Testing agent on Linux native path..."
timeout 15 zeroclaw agent --config-dir "$LINUX_HOME" -m "say hello" 2>&1
echo "EXIT:$?"
