#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

stop_legacy_openclaw_if_present

zeroclaw_pids="$(zeroclaw_daemon_pids)"
if [[ -n "$zeroclaw_pids" ]]; then
	while IFS= read -r pid; do
		[[ -n "$pid" ]] || continue
		kill "$pid" >/dev/null 2>&1 || true
	done <<< "$zeroclaw_pids"
	echo "Stopped zeroclaw daemon"
else
	echo "zeroclaw daemon is not running"
fi

stop_process_from_pid_file "ollama" "$RUNTIME_DIR/ollama.pid"
