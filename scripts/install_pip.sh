#!/usr/bin/env bash
set -euo pipefail
source "$HOME/.cargo/env"

# Download pip bootstrap
python3 - <<'PYEOF'
import urllib.request
print("Downloading pip bootstrap...")
data = urllib.request.urlopen("https://bootstrap.pypa.io/get-pip.py", timeout=30).read()
with open("/tmp/get-pip.py", "wb") as f:
    f.write(data)
print("Downloaded.")
PYEOF

# Install pip breaking system-package lock
python3 /tmp/get-pip.py --break-system-packages
echo "pip installed"
python3 -m pip install --break-system-packages textual
echo "textual installed"
