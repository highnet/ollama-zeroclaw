#!/usr/bin/env bash
set -euo pipefail
source /home/joaquin/.cargo/env

# Fresh test dir
rm -rf /tmp/zc-testdir
cp -r /tmp/zc-fresh /tmp/zc-testdir

# Disable Docker sandbox
python3 - <<'PYEOF'
import re
path = "/tmp/zc-testdir/config.toml"
with open(path) as f:
    txt = f.read()
txt = re.sub(r'backend\s*=\s*"auto"', 'backend = "none"', txt)
with open(path, "w") as f:
    f.write(txt)
print("sandbox backend:", re.search(r'backend\s*=\s*"([^"]+)"', txt).group(1))
PYEOF

timeout 15 zeroclaw agent --config-dir /tmp/zc-testdir -m "hello" 2>&1
echo "EXIT:$?"
