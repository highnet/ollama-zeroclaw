#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.cargo/env"

# Run zeroclaw agent and capture all output including any early exit messages
export ZEROCLAW_CONFIG_DIR=/tmp/zc-testdir
export RUST_LOG=zeroclaw=debug,zeroclaw_runtime=debug,zeroclaw_config=debug

# Redirect to a log file to catch everything
timeout 10 zeroclaw agent --config-dir /tmp/zc-testdir -m "hello" > /tmp/zc-agent.log 2>&1
echo "EXIT:$?"
echo "=== STDOUT+STDERR ==="
cat /tmp/zc-agent.log
