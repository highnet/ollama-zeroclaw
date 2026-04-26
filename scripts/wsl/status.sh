#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "Repository: $REPO_ROOT"
echo "ZeroClaw home: $ZEROCLAW_HOME_DIR"
echo "Model: $ZEROCLAW_MODEL"
echo "Config: $ZEROCLAW_CONFIG_PATH"
echo "Ollama host: $OLLAMA_HOST"
echo

if ollama_host_is_reachable; then
    echo "Ollama: running on $(ollama_host_name):$(ollama_host_port)"
else
    echo "Ollama: stopped"
fi

if is_port_open 127.0.0.1 "${ZEROCLAW_PORT:-18789}"; then
    echo "ZeroClaw daemon: running on 127.0.0.1:${ZEROCLAW_PORT:-18789}"
else
    echo "ZeroClaw daemon: stopped"
fi

echo
if command -v ollama >/dev/null 2>&1; then
    echo "Installed Ollama models:"
    ollama list || true
else
    echo "Installed Ollama models: ollama not installed"
fi

echo
if command -v zeroclaw >/dev/null 2>&1; then
    echo "ZeroClaw version:"
    zeroclaw --help | sed -n '1,2p' || true
else
    echo "ZeroClaw: not installed"
fi
