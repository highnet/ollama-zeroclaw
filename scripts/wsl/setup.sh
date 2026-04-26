#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# REPO_ROOT should point to the repository root (two levels up from scripts/wsl)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime"
LOG_DIR="$REPO_ROOT/logs"
# Use ZEROCLAW_* variable names to match .env
ZEROCLAW_HOME_DIR="$REPO_ROOT/.zeroclaw-home"
ZEROCLAW_ENV_FILE="$REPO_ROOT/.env"
ZEROCLAW_CONFIG_PATH="$ZEROCLAW_HOME_DIR/config.toml"
ZEROCLAW_WEB_DIST_DIR="$ZEROCLAW_HOME_DIR/web-dist"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR" "$ZEROCLAW_HOME_DIR"

if [[ ! -f "$ZEROCLAW_ENV_FILE" ]]; then
    cp "$REPO_ROOT/.env.example" "$ZEROCLAW_ENV_FILE"
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
export ZEROCLAW_PORT="${ZEROCLAW_PORT:-18789}"
export ZEROCLAW_MODEL="$(normalize_ollama_model "${ZEROCLAW_MODEL:-qwen2.5:1.5b}")"

require_cmd() {
    local cmd="$1"
    local resolved
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -z "$resolved" || "$resolved" == /mnt/c/* ]]; then
        echo "Missing required command: $cmd" >&2
        return 1
    fi
}

find_zeroclaw_web_dir() {
    find "$HOME/.cargo/registry/src" -type f -path '*/zeroclaw-*/web/package.json' -print 2>/dev/null \
        | sort -r \
        | head -n 1 \
        | sed 's#/package.json$##'
}

build_gateway_dashboard() {
    local web_dir
    local built_dist_dir

    copy_repo_web_dist() {
        local source_dist_dir="$1"
        mkdir -p "$ZEROCLAW_WEB_DIST_DIR"
        rm -rf "$ZEROCLAW_WEB_DIST_DIR"/*
        cp -R "$source_dist_dir"/. "$ZEROCLAW_WEB_DIST_DIR"/
        echo "Copied dashboard assets to $ZEROCLAW_WEB_DIST_DIR"
    }

    web_dir="$(find_zeroclaw_web_dir || true)"
    if [[ -z "$web_dir" ]]; then
        echo "Skipping dashboard build: could not locate zeroclaw web sources under ~/.cargo/registry/src."
        return 0
    fi

    built_dist_dir="$web_dir/dist"
    if [[ -d "$built_dist_dir" && -f "$built_dist_dir/index.html" ]]; then
        copy_repo_web_dist "$built_dist_dir"
        return 0
    fi

    if ! command -v npm >/dev/null 2>&1; then
        echo "Skipping dashboard build: npm is not installed in WSL."
        return 0
    fi

    echo "Building ZeroClaw web dashboard from $web_dir"
    if [[ -f "$web_dir/package-lock.json" ]]; then
        (cd "$web_dir" && npm ci && npm run build)
    else
        (cd "$web_dir" && npm install && npm run build)
    fi

    built_dist_dir="$web_dir/dist"
    if [[ ! -d "$built_dist_dir" ]]; then
        echo "Skipping dashboard copy: build completed but $built_dist_dir was not found."
        return 0
    fi

    copy_repo_web_dist "$built_dist_dir"
}

ensure_zeroclaw_token() {
    local token
    token="$(read_zeroclaw_token || true)"
    if [[ -n "$token" ]]; then
        printf '%s\n' "$token"
        return 0
    fi

    zeroclaw onboard --non-interactive 2>/dev/null || true
    python3 - <<'PY'
import json, os, sys
dir = os.path.join(os.path.expanduser("~/.zeroclaw-home"), "config")
if os.path.isdir(dir):
    for f in os.listdir(dir):
        if f.endswith(".json"):
            p = os.path.join(dir, f)
            try:
                data = json.load(open(p))
                if isinstance(data, dict) and "token" in data:
                    print(data["token"])
                    sys.exit(0)
            except: pass
PY
}

read_zeroclaw_token() {
    if [[ ! -f "$ZEROCLAW_CONFIG_PATH" ]]; then
        return 1
    fi
    python3 - <<PY
import re, sys
with open(r"$ZEROCLAW_CONFIG_PATH") as f:
    text = f.read()
m = re.search(r'token\s*:\s*"([^"]+)"', text, re.S)
if m:
    print(m.group(1))
PY
}

write_zeroclaw_config() {
    local token
    token="$(ensure_zeroclaw_token)"

    cat > "$ZEROCLAW_CONFIG_PATH" <<EOF
[server]
bind = "0.0.0.0:$ZEROCLAW_PORT"

[auth]
token = "$token"

[model]
provider = "ollama"
primary = "$ZEROCLAW_MODEL"

[defaults]
timeoutSeconds = 300
llm.idleTimeoutSeconds = 300
EOF
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

start_background_process() {
    local name="$1"
    local pid_file="$2"
    local log_file="$3"
    shift 3

    is_live_pid() {
        local pid="$1"
        local state
        if ! kill -0 "$pid" 2>/dev/null; then
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
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid"
        fi
        echo "Stopped $name"
    else
        echo "$name PID file existed but process was not running"
    fi

    rm -f "$pid_file"
}

# ── Ollama: prefer Windows GPU instance, fall back to WSL CPU ─────────────────
# With WSL2 mirrored networking, Windows Ollama is reachable at localhost:11434.
export OLLAMA_HOST="http://localhost:11434"

if is_port_open 127.0.0.1 11434; then
    echo "Ollama reachable at $OLLAMA_HOST (Windows GPU instance)"
else
    echo "Windows Ollama not detected — starting WSL Ollama (CPU fallback)..."
    start_background_process \
        "ollama" \
        "$RUNTIME_DIR/ollama.pid" \
        "$LOG_DIR/ollama.log" \
        ollama serve
    sleep 4
fi

# Pull the model only if not already present
_model_simple="$ZEROCLAW_MODEL"
if ollama list 2>/dev/null | grep -qF "${_model_simple%%:*}"; then
    echo "Model ${_model_simple} already present, skipping pull."
else
    ollama pull "$ZEROCLAW_MODEL" || true
fi

build_gateway_dashboard

# Ensure zeroclaw config exists with correct gateway port, pairing=false, sandbox=none
if [[ ! -f "$ZEROCLAW_CONFIG_PATH" ]]; then
    zeroclaw onboard --quick --force \
        --provider ollama --model "$ZEROCLAW_MODEL" \
        --config-dir "$ZEROCLAW_HOME_DIR" >/dev/null
fi
# Always patch critical settings (idempotent)
python3 - <<PYEOF
import pathlib
import re
p = pathlib.Path(r"$ZEROCLAW_CONFIG_PATH")
repo_web_dist = pathlib.Path(r"$ZEROCLAW_WEB_DIST_DIR")
if not p.exists():
    raise SystemExit(0)
txt = p.read_text()
if re.search(r'(?ms)^\[providers\.models\.ollama\]\n', txt):
    txt = re.sub(
        r'(?ms)(^\[providers\.models\.ollama\]\n.*?^model\s*=\s*")([^"]+)("\s*$)',
        rf'\g<1>$ZEROCLAW_MODEL\g<3>',
        txt,
        count=1,
    )
legacy_channels = re.search(r'(?ms)^\[channels\]\n(.*?)(?=^\[|\Z)', txt)
if legacy_channels:
    legacy_body = legacy_channels.group(1)
    cli_match = re.search(r'^cli\s*=\s*(true|false)\s*$', legacy_body, re.MULTILINE)
    timeout_match = re.search(r'^message_timeout_secs\s*=\s*(\d+)\s*$', legacy_body, re.MULTILINE)
    cli_value = cli_match.group(1) if cli_match else 'true'
    timeout_value = timeout_match.group(1) if timeout_match else '300'
    if re.search(r'(?m)^\[channels_config\]\s*$', txt):
        def merge_channels_config(match):
            body = match.group(1)
            if re.search(r'(?m)^cli\s*=\s*', body):
                body = re.sub(r'(?m)^cli\s*=\s*.*$', f'cli = {cli_value}', body, count=1)
            else:
                body = f'cli = {cli_value}\n' + body
            if re.search(r'(?m)^message_timeout_secs\s*=\s*', body):
                body = re.sub(r'(?m)^message_timeout_secs\s*=\s*.*$', f'message_timeout_secs = {timeout_value}', body, count=1)
            else:
                body = body.rstrip() + f'\nmessage_timeout_secs = {timeout_value}\n'
            return '[channels_config]\n' + body.rstrip() + '\n'

        txt = re.sub(r'(?ms)^\[channels_config\]\n(.*?)(?=^\[|\Z)', merge_channels_config, txt, count=1)
        txt = re.sub(r'(?ms)^\[channels\]\n.*?(?=^\[|\Z)', '', txt, count=1)
    else:
        channels_config_block = (
            '[channels_config]\n'
            f'cli = {cli_value}\n'
            f'message_timeout_secs = {timeout_value}\n'
        )
        txt = re.sub(r'(?ms)^\[channels\]\n.*?(?=^\[|\Z)', channels_config_block, txt, count=1)
# Insert/update [gateway] section port
if '[gateway]' not in txt:
    txt += '\n[gateway]\nport = $ZEROCLAW_PORT\nrequire_pairing = false\n'
else:
    txt = re.sub(r'(port\s*=\s*)\d+', r'\g<1>$ZEROCLAW_PORT', txt, count=1)
    txt = re.sub(r'require_pairing\s*=\s*(true|false)', 'require_pairing = false', txt)
# Prefer repo-local dashboard assets when present, and strip user-local paths otherwise.
gateway_has_web_dist = re.search(r'(?m)^web_dist_dir\s*=\s*"', txt) is not None
if repo_web_dist.is_dir() and any(repo_web_dist.iterdir()):
    replacement = f'web_dist_dir = "{repo_web_dist.as_posix()}"'
    if gateway_has_web_dist:
        txt = re.sub(r'(?m)^web_dist_dir\s*=\s*"[^"]*"\s*$', replacement, txt, count=1)
    else:
        txt = re.sub(r'(?m)^(\[gateway\]\n)', r'\1' + replacement + '\n', txt, count=1)
else:
    txt = re.sub(r'(?m)^web_dist_dir\s*=\s*"[^"]*"\s*\n?', '', txt, count=1)
# Patch sandbox
txt = re.sub(r'(\[security\.sandbox\][^\[]*?backend\s*=\s*)"[^"]+"',
             r'\1"none"', txt, flags=re.DOTALL)
p.write_text(txt)
print("Config patched: gateway=$ZEROCLAW_PORT pairing=false sandbox=none channels_schema=current web_dist=repo-local-or-unset")
PYEOF

# Start ZeroClaw daemon (only if zeroclaw is installed in WSL)
if command -v zeroclaw >/dev/null 2>&1; then
    pkill -f "zeroclaw daemon.*$ZEROCLAW_HOME_DIR" >/dev/null 2>&1 || true
    start_background_process \
        "zeroclaw" \
        "$RUNTIME_DIR/zeroclaw.pid" \
        "$LOG_DIR/zeroclaw.log" \
        zeroclaw daemon --config-dir "$ZEROCLAW_HOME_DIR" --host 0.0.0.0 --port "$ZEROCLAW_PORT"
else
    echo "zeroclaw command not found in WSL. Skipping ZeroClaw daemon start."
    echo "Install ZeroClaw in WSL and re-run scripts/wsl/setup.sh to start the daemon."
    exit 0
fi

sleep 3

if is_port_open 127.0.0.1 "$ZEROCLAW_PORT"; then
    echo "ZeroClaw is up at http://127.0.0.1:$ZEROCLAW_PORT"
    token="$(read_zeroclaw_token)"
    if [[ -n "$token" ]]; then
        echo "Token: $token"
    fi
else
    echo "Warning: ZeroClaw did not start cleanly. Check logs/zeroclaw.log" >&2
fi
