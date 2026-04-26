#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

pkill -f zeroclaw 2>/dev/null && sleep 2 || true

nohup zeroclaw daemon --host 0.0.0.0 --port 18789 > logs/zeroclaw.log 2>&1 &
DAEMON_PID=$!
echo "Daemon PID: $DAEMON_PID"
sleep 4

python3 "$SCRIPT_DIR/test_ollama.py"
python3 - <<'PYEOF'
import urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:18789/health", timeout=5)
    print("[OK] ZeroClaw daemon health:", r.read()[:80])
except Exception as e:
    print("[FAIL] Daemon not reachable:", e)
PYEOF
