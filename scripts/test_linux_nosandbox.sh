#!/usr/bin/env bash
source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LINUX_HOME="$HOME/.zeroclaw-nosandbox"
mkdir -p "$LINUX_HOME"

# Copy the repo's config (which has sandbox=none) 
cp "$REPO_ROOT/.zeroclaw-home/config.toml" "$LINUX_HOME/"

# Init workspace
timeout 10 zeroclaw onboard --quick --force --provider ollama --model qwen2.5:1.5b --config-dir "$LINUX_HOME" 2>&1 | tail -3

# Ensure sandbox=none persists
export LINUX_CONFIG_PATH="$LINUX_HOME/config.toml"
python3 - <<'PYEOF'
import os
import re
path = os.environ["LINUX_CONFIG_PATH"]
with open(path) as f:
    txt = f.read()
txt = re.sub(r'(\[security\.sandbox\][^\[]*?backend\s*=\s*)"[^"]+"', r'\1"none"', txt, flags=re.DOTALL)
with open(path, "w") as f:
    f.write(txt)
import subprocess
out = subprocess.run(["grep", "-A2", r"security.sandbox", path], capture_output=True, text=True)
print("Sandbox config:", out.stdout.strip())
PYEOF

echo ""
echo "=== Testing agent on Linux native path with sandbox=none ==="
timeout 20 zeroclaw agent --config-dir "$LINUX_HOME" -m "say hello" 2>&1
echo "EXIT:$?"
