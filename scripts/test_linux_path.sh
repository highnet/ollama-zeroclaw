#!/usr/bin/env bash
source /home/joaquin/.cargo/env

LINUX_HOME="/home/joaquin/.zeroclaw-repo"
mkdir -p "$LINUX_HOME"

# Copy config from Windows-mounted dir to Linux native dir
cp /mnt/c/Users/joaqu/ollama-openclaw/.zeroclaw-home/config.toml "$LINUX_HOME/"

# Onboard to create workspace files  
timeout 10 zeroclaw onboard --quick --force --provider ollama --model qwen2.5:1.5b --config-dir "$LINUX_HOME" 2>&1 | tail -5

echo ""
echo "Testing agent on Linux native path..."
timeout 15 zeroclaw agent --config-dir "$LINUX_HOME" -m "say hello" 2>&1
echo "EXIT:$?"
