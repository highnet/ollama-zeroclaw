#!/usr/bin/env bash
source /home/joaquin/.cargo/env

LINUX_HOME="/home/joaquin/.zeroclaw-nosandbox"
mkdir -p "$LINUX_HOME"

# Copy the repo's config (which has sandbox=none) 
cp /mnt/c/Users/joaqu/ollama-openclaw/.zeroclaw-home/config.toml "$LINUX_HOME/"

# Init workspace
timeout 10 zeroclaw onboard --quick --force --provider ollama --model qwen2.5:1.5b --config-dir "$LINUX_HOME" 2>&1 | tail -3

# Ensure sandbox=none persists
python3 - <<'PYEOF'
import re
path = "/home/joaquin/.zeroclaw-nosandbox/config.toml"
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
