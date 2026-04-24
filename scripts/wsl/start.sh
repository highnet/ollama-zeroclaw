#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_cmd python3
require_cmd ollama
require_cmd zeroclaw

write_zeroclaw_config
stop_legacy_openclaw_if_present

if ! is_port_open 127.0.0.1 "$OLLAMA_PORT"; then
    start_background_process \
        "ollama" \
        "$RUNTIME_DIR/ollama.pid" \
        "$LOG_DIR/ollama.log" \
        ollama serve
    sleep 4
fi

if ! ollama list | grep -Fq "$ZEROCLAW_MODEL"; then
    echo "Model $ZEROCLAW_MODEL is not present locally. Pulling it now."
    ollama pull "$ZEROCLAW_MODEL"
fi

echo "ZeroClaw TUI is ready"
echo "Config: $ZEROCLAW_CONFIG_PATH"
echo "Model: $ZEROCLAW_MODEL"
echo "Run ./scripts/wsl/tui.sh to enter the terminal UI"
