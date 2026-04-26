#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime"
LOG_DIR="$REPO_ROOT/logs"
ZEROCLAW_HOME_DIR="$REPO_ROOT/.zeroclaw-home"
ZEROCLAW_ENV_FILE="$REPO_ROOT/.env"
ZEROCLAW_TEMPLATE_ENV_FILE="$REPO_ROOT/.env.example"
ZEROCLAW_CONFIG_PATH="$ZEROCLAW_HOME_DIR/config.toml"
ZEROCLAW_SESSION_STATE_FILE="$RUNTIME_DIR/zeroclaw-session.json"

# Prefer native Linux binaries inside WSL before any inherited Windows PATH entries.
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR" "$ZEROCLAW_HOME_DIR"

if [[ ! -f "$ZEROCLAW_ENV_FILE" ]]; then
    cp "$ZEROCLAW_TEMPLATE_ENV_FILE" "$ZEROCLAW_ENV_FILE"
fi

set -a
source <(tr -d '\r' < "$ZEROCLAW_ENV_FILE")
set +a

normalize_ollama_model() {
    local model="$1"
    if [[ "$model" == ollama/* ]]; then
        printf '%s\n' "${model#ollama/}"
    else
        printf '%s\n' "$model"
    fi
}

export ZEROCLAW_HOME="$ZEROCLAW_HOME_DIR"
export ZEROCLAW_CONFIG_DIR="$ZEROCLAW_HOME_DIR"
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama-local}"
export OLLAMA_PORT="${OLLAMA_PORT:-11434}"
export ZEROCLAW_MODEL="$(normalize_ollama_model "${ZEROCLAW_MODEL:-${OPENCLAW_MODEL:-qwen2.5:1.5b}}")"

require_cmd() {
    local cmd="$1"
    local resolved
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -z "$resolved" || "$resolved" == /mnt/c/* ]]; then
        echo "Missing required command: $cmd" >&2
        return 1
    fi
}

write_zeroclaw_config() {
    require_cmd zeroclaw
    mkdir -p "$ZEROCLAW_HOME_DIR"

    zeroclaw onboard \
        --quick \
        --force \
        --config-dir "$ZEROCLAW_HOME_DIR" \
        --provider ollama \
        --model "$ZEROCLAW_MODEL" \
        >/dev/null
}

is_port_open() {
    local host="$1"
    local port="$2"
    python3 - <<PY
import socket
sock = socket.socket()
sock.settimeout(0.5)
try:
    sock.connect(("$host", int("$port")))
except OSError:
    raise SystemExit(1)
else:
    raise SystemExit(0)
finally:
    sock.close()
PY
}

zeroclaw_agent_pids() {
    pgrep -f "zeroclaw agent --config-dir $ZEROCLAW_HOME_DIR" || true
}

zeroclaw_daemon_pids() {
    pgrep -f "zeroclaw daemon" || true
}

stop_legacy_openclaw_if_present() {
    if [[ -f "$RUNTIME_DIR/openclaw.pid" ]]; then
        stop_process_from_pid_file "openclaw" "$RUNTIME_DIR/openclaw.pid"
    fi
}

start_background_process() {
    local name="$1"
    local pid_file="$2"
    local log_file="$3"
    shift 3

    is_live_pid() {
        local pid="$1"
        local state
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            return 1
        fi
        state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$state" && "$state" != Z* ]]
    }

    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(cat "$pid_file")"
        if is_live_pid "$existing_pid"; then
            echo "$name is already running with PID $existing_pid"
            return 0
        fi
        rm -f "$pid_file"
    fi

    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" < /dev/null > "$log_file" 2>&1 &
    else
        nohup "$@" < /dev/null > "$log_file" 2>&1 &
    fi
    echo $! > "$pid_file"
    echo "Started $name with PID $(cat "$pid_file")"
}

stop_process_from_pid_file() {
    local name="$1"
    local pid_file="$2"

    if [[ ! -f "$pid_file" ]]; then
        echo "$name is not running"
        return 0
    fi

    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid"
        sleep 1
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill -9 "$pid"
        fi
        echo "Stopped $name"
    else
        echo "$name PID file existed but process was not running"
    fi

    rm -f "$pid_file"
}
