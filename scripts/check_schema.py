#!/usr/bin/env python3
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = REPO_ROOT / ".zeroclaw-home"

result = subprocess.run(
    ["zeroclaw", "config", "--config-dir", str(CONFIG_DIR), "schema"],
    capture_output=True, text=True, timeout=10
)
schema = json.loads(result.stdout)
def find_keys(d, prefix=""):
    if isinstance(d, dict):
        for k, v in d.items():
            path = f"{prefix}.{k}" if prefix else k
            if any(x in path.lower() for x in ['ollama', 'provider', 'base_url', 'api_url', 'host']):
                print(f"{path}: {json.dumps(v)[:100]}")
            find_keys(v, path)

find_keys(schema)
