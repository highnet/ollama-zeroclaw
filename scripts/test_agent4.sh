#!/usr/bin/env bash
source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Note current log size before agent test
LOG_START_LINE=$(wc -l < logs/zeroclaw.log 2>/dev/null || echo 0)

# Run agent test
timeout 20 zeroclaw agent --config-dir .zeroclaw-home -m "say hello" > /tmp/agent_out.txt 2>&1 &
AGENT_PID=$!

# Let it run up to 15s
sleep 15

echo "=== Agent Output ==="
cat /tmp/agent_out.txt

echo ""
echo "=== New daemon log entries since agent started ==="
tail -n "+$((LOG_START_LINE + 1))" logs/zeroclaw.log

echo "exit:$?"
