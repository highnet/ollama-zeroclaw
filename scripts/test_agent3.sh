#!/usr/bin/env bash
source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Clear old log
echo "" > logs/zeroclaw-agent-test.log

# Start agent in background with 20s timeout
timeout 20 zeroclaw agent --config-dir .zeroclaw-home -m hello > logs/zeroclaw-agent-test.log 2>&1 &
AGENT_PID=$!

# Wait and then check daemon logs
sleep 5
echo "=== AGENT OUTPUT ==="
cat logs/zeroclaw-agent-test.log
echo ""
echo "=== DAEMON LOG (last 30 lines) ==="
tail -30 logs/zeroclaw.log

# Wait for agent
wait $AGENT_PID 2>/dev/null || true
echo ""
echo "=== AGENT OUTPUT AFTER WAIT ==="
cat logs/zeroclaw-agent-test.log
