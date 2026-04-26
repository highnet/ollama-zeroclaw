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
export OLLAMA_WINDOWS_PROXY_PORT="${OLLAMA_WINDOWS_PROXY_PORT:-11435}"
export ZEROCLAW_MODEL="$(normalize_ollama_model "${ZEROCLAW_MODEL:-${OPENCLAW_MODEL:-qwen2.5:1.5b}}")"

force_windows_ollama_gpu() {
    if ! command -v powershell.exe >/dev/null 2>&1; then
        return 1
    fi

    local script
    script="$ollamaExe = Join-Path \$env:LOCALAPPDATA 'Programs\\Ollama\\ollama.exe'; "
    script+="$amdGpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { \$_.Name -match 'AMD|Radeon' } | Select-Object -First 1; "
    script+="if (-not \$amdGpu -or -not (Test-Path \$ollamaExe)) { exit 1 }; "
    script+="[System.Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', '1', 'User'); "
    script+="Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force; "
    script+="\$deadline = (Get-Date).AddSeconds(15); do { \$listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue; if (-not \$listening) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt \$deadline); "
    script+="\$serveScript = \"`$env:OLLAMA_HOST = 'http://127.0.0.1:11434'; `$env:OLLAMA_VULKAN = '1'; & '\" + \$ollamaExe.Replace(\"'\", \"''\") + \"' serve\"; "
    script+="Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', \$serveScript); "
    script+="\$deadline = (Get-Date).AddSeconds(20); do { \$listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue; if (\$listening) { exit 0 }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt \$deadline); "
    script+="exit 1"

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$script" >/dev/null 2>&1
}

resolve_windows_ollama_host() {
    local port="${OLLAMA_PORT:-11434}"
    local proxy_port="${OLLAMA_WINDOWS_PROXY_PORT:-11435}"
    local gateway
    local nameserver
    local candidate

    gateway="$(ip route 2>/dev/null | awk '/^default / {print $3; exit}' || true)"
    nameserver="$(awk '/^nameserver[[:space:]]+/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
    for candidate in \
        "${gateway:+http://$gateway:$proxy_port}" \
        "http://host.docker.internal:$proxy_port" \
        "${nameserver:+http://$nameserver:$port}" \
        "${gateway:+http://$gateway:$port}" \
        "http://host.docker.internal:$port"
    do
        [[ -z "$candidate" ]] && continue
        if curl -fsS --max-time 1 "$candidate/api/tags" >/dev/null 2>&1; then
            printf '%s\n' "${candidate%/}"
            return 0
        fi
    done

    return 1
}

use_local_ollama_host() {
    export OLLAMA_HOST="http://127.0.0.1:${OLLAMA_PORT:-11434}"
}

ollama_host_parts() {
    python3 - <<PY
from urllib.parse import urlparse

url = ${OLLAMA_HOST@Q}
parsed = urlparse(url if '://' in url else f'http://{url}')
host = parsed.hostname or '127.0.0.1'
port = parsed.port or ${OLLAMA_PORT:-11434}
print(host)
print(port)
PY
}

ollama_host_name() {
    ollama_host_parts | sed -n '1p'
}

ollama_host_port() {
    ollama_host_parts | sed -n '2p'
}

ollama_host_is_reachable() {
    is_port_open "$(ollama_host_name)" "$(ollama_host_port)"
}

if [[ -z "${OLLAMA_HOST:-}" ]]; then
    if resolved_ollama_host="$(resolve_windows_ollama_host)"; then
        export OLLAMA_HOST="$resolved_ollama_host"
    else
        use_local_ollama_host
    fi
fi

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
