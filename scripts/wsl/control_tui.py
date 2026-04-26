#!/usr/bin/env python3
"""
ZeroClaw Control TUI — built with Textual
All-in-one: onboarding, service control, chat, settings.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import tomllib
import traceback
import time
from urllib.parse import urlparse
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = (SCRIPT_DIR / "../..").resolve()
ZEROCLAW_HOME = REPO_ROOT / ".zeroclaw-home"
ENV_FILE = REPO_ROOT / ".env"
RUNTIME_DIR = REPO_ROOT / ".runtime"
LOG_DIR = REPO_ROOT / "logs"
SESSION_FILE = RUNTIME_DIR / "session.json"
CARGO_ENV = Path.home() / ".cargo" / "env"
GATEWAY_WEB_DIST_DIR = ZEROCLAW_HOME / "web-dist"

ZEROCLAW_PORT = int(os.environ.get("ZEROCLAW_PORT", "18789"))
OLLAMA_PORT = int(os.environ.get("OLLAMA_PORT", "11434"))
OLLAMA_WINDOWS_PROXY_PORT = int(os.environ.get("OLLAMA_WINDOWS_PROXY_PORT", "11435"))
DEFAULT_MODEL = "qwen2.5:1.5b"


def parse_ollama_host(url: str | None = None) -> tuple[str, int]:
    raw = (url or f"http://127.0.0.1:{OLLAMA_PORT}").strip()
    parsed = urlparse(raw if "://" in raw else f"http://{raw}")
    return parsed.hostname or "127.0.0.1", parsed.port or OLLAMA_PORT


def resolve_windows_ollama_host() -> str | None:
    candidates: list[str] = []
    try:
        route_result = subprocess.run(
            ["ip", "route"],
            capture_output=True,
            text=True,
            check=False,
            env=os.environ.copy(),
        )
        route_lines = route_result.stdout.splitlines()
        for line in route_lines:
            if line.startswith("default "):
                parts = line.split()
                if "via" in parts:
                    gateway = parts[parts.index("via") + 1]
                    candidates.append(f"http://{gateway}:{OLLAMA_WINDOWS_PROXY_PORT}")
                break
    except Exception:
        pass

    try:
        for line in Path("/etc/resolv.conf").read_text().splitlines():
            if line.startswith("nameserver "):
                nameserver = line.split(None, 1)[1].strip()
                if nameserver:
                    candidates.append(f"http://{nameserver}:{OLLAMA_PORT}")
                break
    except OSError:
        pass

    candidates.append(f"http://host.docker.internal:{OLLAMA_WINDOWS_PROXY_PORT}")
    candidates.append(f"http://host.docker.internal:{OLLAMA_PORT}")
    for candidate in candidates:
        host, port = parse_ollama_host(candidate)
        if is_port_open(host, port):
            return candidate.rstrip("/")
    return None


def get_ollama_host() -> str:
    env_file_host = load_env_file().get("OLLAMA_HOST")
    if env_file_host:
        return env_file_host.rstrip("/")
    return resolve_windows_ollama_host() or f"http://127.0.0.1:{OLLAMA_PORT}"


def normalize_ollama_model(model: str) -> str:
    model = model.strip()
    if model.startswith("ollama/"):
        return model.split("/", 1)[1]
    return model


def get_env() -> dict:
    """Base env that includes cargo/local bin in PATH."""
    env = os.environ.copy()
    cargo_bin = str(Path("~/.cargo/bin").expanduser())
    local_bin = str(Path("~/.local/bin").expanduser())
    existing = env.get("PATH", "")
    env["PATH"] = f"{cargo_bin}:{local_bin}:/usr/local/bin:/usr/bin:/bin:{existing}"
    # Load .env if present
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    env.setdefault("OLLAMA_HOST", get_ollama_host())
    env.setdefault("ZEROCLAW_HOME", str(ZEROCLAW_HOME))
    env.setdefault("ZEROCLAW_CONFIG_DIR", str(ZEROCLAW_HOME))
    return env


def get_model() -> str:
    env = get_env()
    return normalize_ollama_model(env.get("ZEROCLAW_MODEL", DEFAULT_MODEL))


def load_env_file() -> dict[str, str]:
    env: dict[str, str] = {}
    if not ENV_FILE.exists():
        return env
    for line in ENV_FILE.read_text().splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key, value = stripped.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def save_env_updates(updates: dict[str, str | None]) -> None:
    existing_lines = ENV_FILE.read_text().splitlines() if ENV_FILE.exists() else []
    output_lines: list[str] = []
    seen: set[str] = set()

    for line in existing_lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in line:
            key, _, _ = line.partition("=")
            key = key.strip()
            if key in updates:
                seen.add(key)
                value = updates[key]
                if value is not None and value != "":
                    output_lines.append(f"{key}={value}")
            else:
                output_lines.append(line)
        else:
            output_lines.append(line)

    for key, value in updates.items():
        if key not in seen and value is not None and value != "":
            output_lines.append(f"{key}={value}")

    ENV_FILE.write_text("\n".join(output_lines).rstrip() + "\n")


def load_zeroclaw_config() -> dict:
    config = ZEROCLAW_HOME / "config.toml"
    if not config.exists():
        return {}
    return tomllib.loads(config.read_text())


def normalize_identity(value: str) -> str:
    return value.strip().lstrip("@")


def parse_allowed_users(raw: str) -> list[str]:
    candidates = [normalize_identity(item) for item in raw.split(",")]
    values = [item for item in candidates if item]
    return values or ["*"]


def get_telegram_settings() -> dict[str, str | bool]:
    config = load_zeroclaw_config()
    telegram = config.get("channels_config", {}).get("telegram", {})
    env = load_env_file()
    allowed_users = telegram.get("allowed_users", ["*"])
    if isinstance(allowed_users, str):
        allowed_users = [allowed_users]
    return {
        "bot_token": telegram.get("bot_token", ""),
        "allowed_users": ", ".join(allowed_users) if allowed_users else "*",
        "bind_identity": env.get("ZEROCLAW_TELEGRAM_IDENTITY", ""),
        "mention_only": bool(telegram.get("mention_only", False)),
        "interrupt_on_new_message": bool(telegram.get("interrupt_on_new_message", False)),
    }


def _format_toml_bool(value: bool) -> str:
    return "true" if value else "false"


def _format_toml_list(values: list[str]) -> str:
    return "[" + ", ".join(json.dumps(item) for item in values) + "]"


def upsert_toml_section(text: str, section: str, body_lines: list[str]) -> str:
    block = f"[{section}]\n" + "\n".join(body_lines).rstrip() + "\n"
    pattern = rf"(?ms)^\[{re.escape(section)}\]\n.*?(?=^\[|\Z)"
    if re.search(pattern, text):
        return re.sub(pattern, block, text)
    return text.rstrip() + "\n\n" + block


def configure_telegram_channel(bot_token: str, allowed_users_raw: str,
                               bind_identity: str = "",
                               mention_only: bool = False,
                               interrupt_on_new_message: bool = False) -> None:
    ensure_zeroclaw_config()
    config = ZEROCLAW_HOME / "config.toml"
    text = config.read_text() if config.exists() else ""
    allowed_users = parse_allowed_users(allowed_users_raw)
    text = upsert_toml_section(text, "channels_config.telegram", [
        f"bot_token = {json.dumps(bot_token.strip())}",
        f"allowed_users = {_format_toml_list(allowed_users)}",
        'stream_mode = "off"',
        f"mention_only = {_format_toml_bool(mention_only)}",
        f"interrupt_on_new_message = {_format_toml_bool(interrupt_on_new_message)}",
    ])
    config.write_text(text)
    save_env_updates({
        "ZEROCLAW_TELEGRAM_IDENTITY": normalize_identity(bind_identity) or None,
    })


def bind_telegram_identity(identity: str) -> tuple[bool, str]:
    normalized = normalize_identity(identity)
    if not normalized:
        return True, "Telegram identity binding skipped"
    result = run([
        "zeroclaw",
        "--config-dir", str(ZEROCLAW_HOME),
        "channel", "bind-telegram", normalized,
    ])
    if result.returncode == 0:
        config = ZEROCLAW_HOME / "config.toml"
        _patch_zeroclaw_config(config)
        output = (result.stdout or "").strip()
        return True, output or f"Bound Telegram identity {normalized}"
    detail = ((result.stderr or result.stdout) or "Failed to bind Telegram identity").strip()
    return False, detail[:400]


def has_telegram_channel() -> bool:
    telegram = load_zeroclaw_config().get("channels_config", {}).get("telegram", {})
    return bool(telegram.get("bot_token"))


def configure_telegram_channel_and_bind(bot_token: str, allowed_users_raw: str,
                                        bind_identity: str = "") -> tuple[bool, str]:
    configure_telegram_channel(bot_token, allowed_users_raw, bind_identity)
    stop_daemon()
    ok, message = start_daemon()
    if not ok:
        return False, message
    bind_ok, bind_message = bind_telegram_identity(bind_identity)
    if not bind_ok:
        return False, bind_message
    if normalize_identity(bind_identity):
        return True, f"Telegram channel configured and bound to {normalize_identity(bind_identity)}"
    return True, "Telegram channel configured"


def is_port_open(host: str, port: int, timeout: float = 0.3) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    kwargs.setdefault("env", get_env())
    return subprocess.run(cmd, **kwargs)


def wait_for_port_state(host: str, port: int, should_be_open: bool,
                        timeout: float = 10.0, interval: float = 0.25) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if is_port_open(host, port) == should_be_open:
            return True
        time.sleep(interval)
    return is_port_open(host, port) == should_be_open


def run_windows_powershell(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True,
        text=True,
    )


def force_windows_ollama_gpu() -> bool:
    script = (
        "$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\\Ollama\\ollama.exe'; "
        "$amdGpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | "
        "Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1; "
        "if (-not $amdGpu -or -not (Test-Path $ollamaExe)) { exit 1 }; "
        "[System.Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', '1', 'User'); "
        "Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force; "
        "$deadline = (Get-Date).AddSeconds(15); "
        "do { $listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue; "
        "if (-not $listening) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline); "
        "$escapedExe = $ollamaExe.Replace(\"'\", \"''\"); "
        "$serveScript = \"$env:OLLAMA_HOST = 'http://127.0.0.1:11434'; $env:OLLAMA_VULKAN = '1'; & '$escapedExe' serve\"; "
        "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $serveScript); "
        "$deadline = (Get-Date).AddSeconds(20); "
        "do { $listening = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue; "
        "if ($listening) { exit 0 }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline); "
        "exit 1"
    )
    return run_windows_powershell(script).returncode == 0


def read_log_tail(path: Path, max_lines: int = 8) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(lines[-max_lines:]).strip()


def extract_zeroclaw_response(raw: str) -> str:
    """Extract the agent reply from zeroclaw's mixed log+output."""
    lines = []
    for line in raw.splitlines():
        stripped = line.strip()
        # Skip zeroclaw log lines (timestamps or empty)
        if re.match(r"^\d{4}-\d{2}-\d{2}T", stripped):
            continue
        if stripped.startswith("🤔"):
            continue
        lines.append(line)
    result = "\n".join(lines).strip()
    return result or "(no response)"


# ---------------------------------------------------------------------------
# Onboarding checks
# ---------------------------------------------------------------------------

class OnboardStatus:
    """Snapshot of what's installed / running."""

    def __init__(self):
        _ollama = shutil.which("ollama")
        self.ollama_bin: bool = bool(_ollama and not _ollama.startswith("/mnt/"))
        self.zeroclaw_bin: bool = self._has_zeroclaw()
        ollama_host, ollama_port = parse_ollama_host(get_ollama_host())
        self.ollama_running: bool = is_port_open(ollama_host, ollama_port)
        self.model_pulled: bool = self._model_pulled()
        self.daemon_running: bool = is_port_open("127.0.0.1", ZEROCLAW_PORT)
        self.config_ok: bool = (ZEROCLAW_HOME / "config.toml").exists()

    def _has_zeroclaw(self) -> bool:
        for p in [Path("~/.cargo/bin/zeroclaw").expanduser(),
                  Path("/usr/local/bin/zeroclaw")]:
            if p.exists():
                return True
        return bool(shutil.which("zeroclaw"))

    def _model_pulled(self) -> bool:
        if not self.ollama_running:
            return False
        try:
            r = run(["ollama", "list"])
            return get_model() in r.stdout
        except Exception:
            return False

    @property
    def ready(self) -> bool:
        return (self.ollama_bin and self.zeroclaw_bin and self.ollama_running
                and self.model_pulled and self.daemon_running and self.config_ok)


# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

def start_ollama() -> bool:
    """Return True if Ollama is reachable (Windows GPU instance preferred).
    Only falls back to spawning WSL ollama if there is truly nothing on the port."""
    env = get_env()
    if force_windows_ollama_gpu():
        env["OLLAMA_HOST"] = resolve_windows_ollama_host() or f"http://127.0.0.1:{OLLAMA_PORT}"
        ollama_host, ollama_port = parse_ollama_host(env.get("OLLAMA_HOST"))
        if wait_for_port_state(ollama_host, ollama_port, True, timeout=12.0):
            return True

    ollama_host, ollama_port = parse_ollama_host(env.get("OLLAMA_HOST"))
    if is_port_open(ollama_host, ollama_port):
        return True

    # Prefer Windows Ollama from the TUI as well, otherwise Stop/Start becomes inconsistent.
    windows_start = run_windows_powershell(
        "$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\\Ollama\\ollama.exe'; "
        "$envVars = @{ OLLAMA_HOST = 'http://127.0.0.1:11434' }; "
        "$amdGpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | "
        "Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1; "
        "if ($amdGpu) { $envVars['OLLAMA_VULKAN'] = '1' }; "
        "$startInfo = New-Object System.Diagnostics.ProcessStartInfo; "
        "$startInfo.FileName = $ollamaExe; "
        "$startInfo.UseShellExecute = $false; "
        "$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden; "
        "foreach ($entry in $envVars.GetEnumerator()) { $startInfo.Environment[$entry.Key] = $entry.Value }; "
        "if (Test-Path $ollamaExe) { [System.Diagnostics.Process]::Start($startInfo) | Out-Null; exit 0 } "
        "exit 1"
    )
    if windows_start.returncode == 0 and wait_for_port_state(ollama_host, ollama_port, True, timeout=8.0):
        return True

    # Fall back to spawning WSL Ollama.
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    log = open(LOG_DIR / "ollama.log", "a")
    env["OLLAMA_HOST"] = f"http://127.0.0.1:{OLLAMA_PORT}"
    proc = subprocess.Popen(["ollama", "serve"], stdout=log, stderr=log,
                             env=env, start_new_session=True)
    pid_file = RUNTIME_DIR / "ollama.pid"
    pid_file.write_text(str(proc.pid))
    return wait_for_port_state("127.0.0.1", OLLAMA_PORT, True, timeout=10.0)


def stop_ollama() -> str:
    messages: list[str] = []
    pid_file = RUNTIME_DIR / "ollama.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 15)
            messages.append(f"Stopped WSL Ollama PID {pid}")
        except (ProcessLookupError, ValueError):
            messages.append("WSL Ollama was already stopped")
        finally:
            pid_file.unlink(missing_ok=True)

    run(["pkill", "-f", "ollama serve"])
    stopped_windows = run_windows_powershell(
        "$p = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue; "
        "if ($p) { $p | Stop-Process -Force; exit 0 } "
        "exit 0"
    )
    if stopped_windows.returncode == 0:
        messages.append("Stopped Windows Ollama if it was running")

    if wait_for_port_state("127.0.0.1", OLLAMA_PORT, False, timeout=10.0):
        return "; ".join(messages) or "Ollama stopped"
    return "Ollama stop requested, but port 11434 is still open"


def pull_model() -> tuple[bool, str]:
    model = get_model()
    simple = model.split("/")[-1]
    r = run(["ollama", "pull", simple])
    if r.returncode == 0:
        return True, f"Pulled {simple}"
    return False, r.stderr[:200]


def open_gateway_dashboard() -> tuple[bool, str]:
    url = f"http://127.0.0.1:{ZEROCLAW_PORT}/"
    windows_open = run_windows_powershell(f"Start-Process '{url}'")
    if windows_open.returncode == 0:
        return True, f"Opened browser dashboard at {url}"

    xdg_open = shutil.which("xdg-open")
    if xdg_open:
        opened = subprocess.run([xdg_open, url], capture_output=True, text=True)
        if opened.returncode == 0:
            return True, f"Opened browser dashboard at {url}"

    detail = windows_open.stderr.strip() or windows_open.stdout.strip() or "failed to start a browser"
    return False, f"Could not open browser dashboard: {detail}"


def start_daemon() -> tuple[bool, str]:
    if is_port_open("127.0.0.1", ZEROCLAW_PORT):
        return True, "Daemon already running"

    stop_daemon()
    ensure_zeroclaw_config()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    log = open(LOG_DIR / "zeroclaw.log", "a")
    proc = subprocess.Popen(
        [
            "zeroclaw", "daemon",
            "--config-dir", str(ZEROCLAW_HOME),
            "--host", "0.0.0.0",
            "--port", str(ZEROCLAW_PORT),
        ],
        stdout=log, stderr=log, env=get_env(), start_new_session=True
    )
    pid_file = RUNTIME_DIR / "zeroclaw.pid"
    pid_file.write_text(str(proc.pid))
    if wait_for_port_state("127.0.0.1", ZEROCLAW_PORT, True, timeout=10.0):
        return True, f"Daemon started (PID {proc.pid})"
    if proc.poll() is not None:
        tail = read_log_tail(LOG_DIR / "zeroclaw.log")
        if tail:
            return False, f"Daemon exited early. Recent log:\n{tail}"
    return False, "Daemon did not start in time"


def stop_daemon() -> str:
    pid_file = RUNTIME_DIR / "zeroclaw.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 15)
        except (ProcessLookupError, ValueError):
            pass
        finally:
            pid_file.unlink(missing_ok=True)
    run(["pkill", "-f", "zeroclaw daemon"])
    if wait_for_port_state("127.0.0.1", ZEROCLAW_PORT, False, timeout=10.0):
        return "ZeroClaw daemon stopped"
    return "Stop requested, but ZeroClaw port is still open"


def ensure_zeroclaw_config():
    """Run zeroclaw onboard if config doesn't exist or is in bad state."""
    ZEROCLAW_HOME.mkdir(parents=True, exist_ok=True)
    config = ZEROCLAW_HOME / "config.toml"
    if not config.exists():
        run(["zeroclaw", "onboard", "--quick", "--force",
             "--provider", "ollama", "--model", get_model(),
             "--config-dir", str(ZEROCLAW_HOME)])
    # Ensure critical settings
    _patch_zeroclaw_config(config)


def _patch_zeroclaw_config(config: Path):
    """Ensures gateway port, pairing=false, sandbox=none, repo-local dashboard assets, and current channel schema."""
    if not config.exists():
        return
    text = config.read_text()
    if re.search(r'(?ms)^\[providers\.models\.ollama\]\n', text):
        text = re.sub(
            r'(?ms)(^\[providers\.models\.ollama\]\n.*?^model\s*=\s*")([^"]+)("\s*$)',
            rf'\g<1>{get_model()}\g<3>',
            text,
            count=1,
        )
    legacy_channels = re.search(r'(?ms)^\[channels\]\n(.*?)(?=^\[|\Z)', text)
    if legacy_channels:
        legacy_body = legacy_channels.group(1)
        cli_match = re.search(r'^cli\s*=\s*(true|false)\s*$', legacy_body, re.MULTILINE)
        timeout_match = re.search(r'^message_timeout_secs\s*=\s*(\d+)\s*$', legacy_body, re.MULTILINE)
        cli_value = cli_match.group(1) if cli_match else 'true'
        timeout_value = timeout_match.group(1) if timeout_match else '300'
        if re.search(r'(?m)^\[channels_config\]\s*$', text):
            def merge_channels_config(match: re.Match[str]) -> str:
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

            text = re.sub(r'(?ms)^\[channels_config\]\n(.*?)(?=^\[|\Z)', merge_channels_config, text, count=1)
            text = re.sub(r'(?ms)^\[channels\]\n.*?(?=^\[|\Z)', '', text, count=1)
        else:
            channels_config_block = (
                '[channels_config]\n'
                f'cli = {cli_value}\n'
                f'message_timeout_secs = {timeout_value}\n'
            )
            text = re.sub(r'(?ms)^\[channels\]\n.*?(?=^\[|\Z)', channels_config_block, text, count=1)
    legacy_telegram = re.search(r'(?ms)^\[channels\.telegram\]\n(.*?)(?=^\[|\Z)', text)
    if legacy_telegram:
        legacy_body = legacy_telegram.group(1).rstrip()
        replacement = '[channels_config.telegram]\n'
        if legacy_body:
            replacement += legacy_body + '\n'
        if re.search(r'(?m)^\[channels_config\.telegram\]\s*$', text):
            text = re.sub(r'(?ms)^\[channels\.telegram\]\n.*?(?=^\[|\Z)', '', text, count=1)
        else:
            text = re.sub(r'(?ms)^\[channels\.telegram\]\n.*?(?=^\[|\Z)', replacement, text, count=1)
    if '[gateway]' not in text:
        text = text.rstrip() + f'\n\n[gateway]\nport = {ZEROCLAW_PORT}\nrequire_pairing = false\n'
    else:
        text = re.sub(r'(port\s*=\s*)\d+', rf'\g<1>{ZEROCLAW_PORT}',
                      text, count=1)
        text = re.sub(r'require_pairing\s*=\s*(true|false)', 'require_pairing = false', text)
    # Prefer repo-local dashboard assets and strip stale user-specific cargo paths.
    if GATEWAY_WEB_DIST_DIR.is_dir() and any(GATEWAY_WEB_DIST_DIR.iterdir()):
        replacement = f'web_dist_dir = "{GATEWAY_WEB_DIST_DIR.as_posix()}"'
        if re.search(r'(?m)^web_dist_dir\s*=\s*"', text):
            text = re.sub(r'(?m)^web_dist_dir\s*=\s*"[^"]*"\s*$', replacement, text, count=1)
        else:
            text = re.sub(r'(?m)^(\[gateway\]\n)', r'\1' + replacement + '\n', text, count=1)
    else:
        text = re.sub(r'(?m)^web_dist_dir\s*=\s*"[^"]*"\s*\n?', '', text, count=1)
    # Patch sandbox backend
    text = re.sub(r'(\[security\.sandbox\][^\[]*?backend\s*=\s*)"[^"]+"',
                  r'\1"none"', text, flags=re.DOTALL)
    config.write_text(text)


# ---------------------------------------------------------------------------
# Chat engine
# ---------------------------------------------------------------------------

class ChatEngine:
    """Wraps zeroclaw agent -m for single-shot queries with session persistence."""

    def __init__(self):
        self.session_file = SESSION_FILE
        self.config_dir = ZEROCLAW_HOME
        SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)

    def send(self, message: str, on_response, on_error) -> threading.Thread:
        """Non-blocking: runs zeroclaw agent in a background thread."""

        def worker():
            try:
                cmd = [
                    "zeroclaw", "agent",
                    "--config-dir", str(self.config_dir),
                    "--session-state-file", str(self.session_file),
                    "-m", message,
                ]
                env = get_env()
                # TERM=dumb prevents zeroclaw from emitting ANSI escape sequences
                # that would be piped into stdout and corrupt response parsing.
                env["TERM"] = "dumb"
                env["NO_COLOR"] = "1"
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    env=env, text=True
                )
                stdout, stderr = proc.communicate(timeout=300)
                # Try stdout first; some zeroclaw builds write to stderr
                response = extract_zeroclaw_response(stdout)
                if not response or response == "(no response)":
                    response = extract_zeroclaw_response(stderr)
                if proc.returncode != 0 and (not response or response == "(no response)"):
                    on_error(f"Exit {proc.returncode}: {(stderr or stdout)[:400]}")
                else:
                    on_response(response)
            except subprocess.TimeoutExpired:
                proc.kill()
                on_error("Timed out (300s). The model may be overloaded — try again.")
            except Exception as exc:
                on_error(str(exc))

        t = threading.Thread(target=worker, daemon=True)
        t.start()
        return t


# ---------------------------------------------------------------------------
# Textual TUI
# ---------------------------------------------------------------------------

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import (
    Button, Footer, Header, Input, Label, ListItem, ListView,
    LoadingIndicator, Markdown, ProgressBar, RichLog, Rule,
    Static, Switch, TabbedContent, TabPane,
)
from textual.worker import Worker, WorkerState


# ── ONBOARDING SCREEN ────────────────────────────────────────────────────────

ONBOARD_CSS = """
OnboardScreen {
    background: $surface;
    align: center middle;
}
#onboard-card {
    width: 72;
    height: auto;
    border: thick $primary;
    padding: 1 2;
    background: $panel;
}
.ob-title {
    text-align: center;
    text-style: bold;
    color: $primary;
    padding: 0 0 1 0;
}
.ob-step {
    margin: 0 0 0 2;
    color: $text;
}
.ok  { color: $success; }
.bad { color: $error; }
.warn { color: $warning; }
#ob-progress { margin: 1 0; }
#ob-log-scroll { height: 16; border: solid $primary-darken-3; padding: 0 1; margin: 1 0; }
#ob-log { height: auto; }
#ob-buttons { align: center middle; margin-top: 1; }
#ob-buttons.hidden { display: none; }
"""


class OnboardScreen(Screen):
    CSS = ONBOARD_CSS
    BINDINGS = [("escape", "app.pop_screen", "Back")]
    _log_content: str = ""

    def __init__(self):
        super().__init__()
        self._setup_started = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Container(id="onboard-card"):
            yield Label("🦀  ZeroClaw Setup Wizard", classes="ob-title")
            yield Rule()
            yield Label("Checking your environment…", id="ob-status", classes="ob-step")
            yield ProgressBar(id="ob-progress", total=6, show_eta=False)
            with ScrollableContainer(id="ob-log-scroll"):
                yield Static("", id="ob-log")
            with Horizontal(id="ob-buttons"):
                yield Button("Retry", id="btn-run-setup", variant="primary")
                yield Button("Close  [Esc]", id="btn-close-onboard", variant="default")
        yield Footer()

    def on_mount(self):
        self.query_one("#ob-buttons", Horizontal).add_class("hidden")
        self.run_worker(self._check_env, exclusive=True, thread=True)

    def _check_env(self):
        self.app.call_from_thread(self._update_log, "📋  Scanning environment…\n")
        status = OnboardStatus()
        steps = [
            (status.ollama_bin, "ollama binary", "Install Ollama: curl -fsSL https://ollama.ai/install.sh | sh"),
            (status.zeroclaw_bin, "zeroclaw binary", "cargo install zeroclaw"),
            (status.ollama_running, "Ollama service", "Will be started by 'Run Setup'"),
            (status.model_pulled, f"model {get_model()}", "Will be pulled by 'Run Setup'"),
            (status.daemon_running, "ZeroClaw daemon", "Will be started by 'Run Setup'"),
            (status.config_ok, "ZeroClaw config", "Will be prepared automatically"),
        ]
        bar = self.query_one("#ob-progress", ProgressBar)
        for i, (ok, name, hint) in enumerate(steps):
            icon = "✅" if ok else "❌"
            self.app.call_from_thread(
                self._update_log, f"{icon} {name}\n"
            )
            self.app.call_from_thread(bar.advance, 1)
            if not ok:
                self.app.call_from_thread(
                    self._update_log, f"   ↳ {hint}\n", "warn"
                )
            time.sleep(0.15)

        self.app.call_from_thread(
            self.query_one("#ob-status", Label).update,
            "Preparing automatic setup…",
        )
        self.app.call_from_thread(self._schedule_setup)

    def _update_log(self, text: str, style: str = ""):
        self._log_content += text
        self.query_one("#ob-log", Static).update(self._log_content)
        # Scroll to bottom so latest output is always visible
        scroller = self.query_one("#ob-log-scroll", ScrollableContainer)
        scroller.scroll_end(animate=False)

    def _stream_cmd_to_log(self, cmd: list[str], log_fn) -> int:
        """Run cmd, stream stdout+stderr line-by-line to log_fn. Return exit code."""
        env = get_env()
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                env=env,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                log_fn(line)
            proc.wait()
            return proc.returncode
        except FileNotFoundError:
            log_fn(f"Command not found: {cmd[0]}\n")
            return 127
        except Exception as exc:
            log_fn(f"Error running {cmd[0]}: {exc}\n")
            return -1

    def _schedule_setup(self):
        if self._setup_started:
            return
        self._setup_started = True
        self.query_one("#ob-buttons", Horizontal).add_class("hidden")
        self.query_one("#ob-status", Label).update("Preparing onboarding…")
        asyncio.create_task(self.run_setup())

    @on(Button.Pressed, "#btn-run-setup")
    def retry_setup(self):
        self._schedule_setup()

    async def run_setup(self):
        try:
            self.query_one("#ob-buttons", Horizontal).add_class("hidden")
            self._update_log("🚀  Running automatic setup…\n\n")

            # ── Step 1: Ollama ──────────────────────────────────────────────
            self._update_log("━━  Step 1/4: Ollama service\n")
            ok = await asyncio.to_thread(start_ollama)
            self._update_log(f"{'✅' if ok else '❌'}  Ollama {'reachable' if ok else 'could not start'}\n\n")
            if not ok:
                self.query_one("#ob-status", Label).update("Ollama failed to start")
                self._update_log("⚠️  Fix the Ollama issue and press Retry.\n")
                self.query_one("#ob-buttons", Horizontal).remove_class("hidden")
                self._setup_started = False
                return

            # ── Step 2: Pull model (non-interactive, streamed into log) ──────
            model = get_model()
            self._update_log(f"━━  Step 2/4: Pull model ({model})\n")

            def _pull():
                def log_cb(text):
                    self.app.call_from_thread(self._update_log, text)
                return self._stream_cmd_to_log(["ollama", "pull", model.split("/")[-1]], log_cb)

            rc = await asyncio.to_thread(_pull)
            self._update_log(
                f"{'✅' if rc == 0 else '⚠️ '}  Model {'pulled' if rc == 0 else f'pull exited {rc}'}\n\n"
            )
            if rc != 0:
                self.query_one("#ob-status", Label).update("Model pull failed")
                self._update_log("⚠️  Fix the model pull issue and press Retry.\n")
                self.query_one("#ob-buttons", Horizontal).remove_class("hidden")
                self._setup_started = False
                return

            # ── Step 3: automatic ZeroClaw configuration ───────────────────
            self.query_one("#ob-status", Label).update("Preparing ZeroClaw configuration…")
            self._update_log("━━  Step 3/4: ZeroClaw configuration\n")
            await asyncio.to_thread(ensure_zeroclaw_config)
            self._update_log("✅  ZeroClaw config prepared\n\n")

            # ── Step 4: daemon start + optional Telegram bind ──────────────
            self.query_one("#ob-status", Label).update("Starting ZeroClaw services…")
            self._update_log("━━  Step 4/4: ZeroClaw services\n")
            ok, message = await asyncio.to_thread(start_daemon)
            self._update_log(f"{'✅' if ok else '❌'}  {message}\n")
            if not ok:
                self.query_one("#ob-status", Label).update("ZeroClaw daemon failed to start")
                self._update_log("⚠️  Fix the daemon issue and press Retry.\n")
                self.query_one("#ob-buttons", Horizontal).remove_class("hidden")
                self._setup_started = False
                return

            telegram_identity = load_env_file().get("ZEROCLAW_TELEGRAM_IDENTITY", "")
            if has_telegram_channel() and telegram_identity.strip():
                bind_ok, bind_message = await asyncio.to_thread(bind_telegram_identity, telegram_identity)
                self._update_log(f"{'✅' if bind_ok else '⚠️ '}  {bind_message}\n")
            else:
                self._update_log("ℹ️  Telegram channel not configured; skipping channel bind\n")

            self.query_one("#ob-status", Label).update("Automatic setup complete")
            self._update_log("\n✅  Automatic setup complete. Opening the control panel…\n")
            await asyncio.sleep(0.8)
            self.app.pop_screen()
            return
        except asyncio.CancelledError:
            # App shutdown can cancel in-flight setup work; treat this as clean.
            return

    @on(Button.Pressed, "#btn-close-onboard")
    def close_onboard(self):
        self.app.pop_screen()


# ── SELF-TEST SCREEN ─────────────────────────────────────────────────────────

SELFTEST_CSS = """
SelfTestScreen {
    background: $surface;
    align: center middle;
}
#selftest-card {
    width: 80;
    height: auto;
    max-height: 90vh;
    border: thick $primary;
    padding: 1 2;
    background: $panel;
}
.st-title {
    text-align: center;
    text-style: bold;
    color: $primary;
    padding: 0 0 1 0;
}
#st-scroll { height: 24; border: solid $primary-darken-3; padding: 0 1; margin: 1 0; }
#st-log { height: auto; }
#st-buttons { align: center middle; margin-top: 1; }
"""


class SelfTestScreen(Screen):
    CSS = SELFTEST_CSS
    BINDINGS = [("escape", "app.pop_screen", "Close")]
    _log_content: str = ""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Container(id="selftest-card"):
            yield Label("🧪  ZeroClaw Self-Test", classes="st-title")
            yield Rule()
            yield Label("Running…", id="st-status")
            with ScrollableContainer(id="st-scroll"):
                yield Static("", id="st-log")
            with Horizontal(id="st-buttons"):
                yield Button("Close  [Esc]", id="btn-st-close", variant="primary")
        yield Footer()

    def on_mount(self):
        self.run_worker(self._run_test, exclusive=True, thread=True)

    def _run_test(self):
        _ansi = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
        def strip(s: str) -> str:
            return _ansi.sub("", s)
        self._append("Running zeroclaw self-test…\n\n")
        r = run(["zeroclaw", "self-test", "--config-dir", str(ZEROCLAW_HOME)])
        output = strip((r.stdout + r.stderr).strip())
        if output:
            self._append(output + "\n")
        else:
            self._append("(zeroclaw self-test produced no output)\n")
        result_line = f"\n{'✅  Passed' if r.returncode == 0 else '❌  Failed'} (exit {r.returncode})"
        self._append(result_line + "\n")
        self.app.call_from_thread(
            self.query_one("#st-status", Label).update,
            "✅  Done — all checks complete" if r.returncode == 0
            else f"❌  Finished with failures (exit {r.returncode})",
        )

    def _append(self, text: str):
        def _update():
            self._log_content += text
            self.query_one("#st-log", Static).update(self._log_content)
            self.query_one("#st-scroll", ScrollableContainer).scroll_end(animate=False)
        self.app.call_from_thread(_update)

    @on(Button.Pressed, "#btn-st-close")
    def close_screen(self):
        self.app.pop_screen()


# ── CHAT MESSAGE WIDGET ───────────────────────────────────────────────────────

class ChatBubble(Static):
    DEFAULT_CSS = """
    ChatBubble {
        padding: 0 1;
        margin-bottom: 1;
    }
    ChatBubble.user {
        background: $primary-darken-3;
        color: $text;
        border-left: thick $primary;
        margin-left: 8;
    }
    ChatBubble.agent {
        background: $surface-darken-1;
        color: $text;
        border-left: thick $success;
        margin-right: 8;
    }
    ChatBubble.system {
        color: $text-muted;
        text-align: center;
    }
    ChatBubble.error {
        background: $error-darken-3;
        border-left: thick $error;
    }
    .chat-role {
        text-style: bold;
        color: $text-muted;
        padding-bottom: 0;
    }
    """

    def __init__(self, role: str, content: str):
        super().__init__(classes=role)
        self.role = role
        self.content = content

    def compose(self) -> ComposeResult:
        icons = {"user": "You", "agent": "🦀 ZeroClaw", "system": "ℹ", "error": "⚠ Error"}
        if self.role not in ("system",):
            yield Label(icons.get(self.role, self.role), classes="chat-role")
        yield Markdown(self.content)


# ── CHAT SCREEN (TAB PANE) ────────────────────────────────────────────────────

CHAT_CSS = """
#chat-messages {
    height: 1fr;
    border: solid $primary-darken-2;
    padding: 0 1;
}
#chat-input-row {
    height: auto;
    margin-top: 1;
}
#chat-input {
    width: 1fr;
}
#btn-send {
    width: 10;
    margin-left: 1;
}
#thinking-bar {
    height: 1;
    color: $warning;
}
"""


# ── DASHBOARD (TAB PANE) ──────────────────────────────────────────────────────

DASH_CSS = """
.service-card {
    width: 1fr;
    height: 10;
    border: solid $primary-darken-2;
    padding: 1;
    margin: 0 1;
}
.service-name {
    text-style: bold;
    color: $primary;
}
.service-status {
    margin-top: 1;
}
.running { color: $success; }
.stopped { color: $error; }
.card-btns {
    margin-top: 1;
    height: auto;
    width: auto;
}
.card-btns Button {
    width: 12;
    min-width: 9;
    margin-right: 1;
}
#dash-log {
    height: 12;
    border: solid $primary-darken-2;
    margin-top: 1;
}
"""


# ── SETTINGS (TAB PANE) ───────────────────────────────────────────────────────

SETTINGS_CSS = """
.settings-row {
    height: auto;
    padding: 0 1;
    margin-bottom: 1;
}
.settings-label {
    width: 22;
    text-style: bold;
}
#btn-save-settings {
    margin-top: 1;
}
"""


# ── MAIN APP ──────────────────────────────────────────────────────────────────

APP_CSS = """
App {
    background: $surface;
}
Header {
    background: $primary-darken-2;
}
Footer {
    background: $primary-darken-3;
}
TabbedContent {
    height: 1fr;
}
"""


class ZeroClawTUI(App):
    TITLE = "🦀 ZeroClaw Control Panel"
    CSS = (APP_CSS + DASH_CSS + CHAT_CSS + SETTINGS_CSS)
    BINDINGS = [
        Binding("ctrl+q", "quit", "Quit"),
        Binding("ctrl+l", "clear_chat", "Clear chat"),
        Binding("f1", "tab_dash", "Dashboard", show=True),
        Binding("f2", "tab_chat", "Chat", show=True),
        Binding("f3", "tab_settings", "Settings", show=True),
    ]

    thinking: reactive[bool] = reactive(False)
    ollama_status: reactive[str] = reactive("unknown")
    daemon_status: reactive[str] = reactive("unknown")

    def __init__(self):
        super().__init__()
        self._chat_engine = ChatEngine()
        self._chat_history: list[dict] = []

    # ── Layout ────────────────────────────────────────────────────────

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(id="tabs"):
            with TabPane("📊 Dashboard [F1]", id="tab-dash"):
                yield from self._compose_dashboard()
            with TabPane("💬 Chat [F2]", id="tab-chat"):
                yield from self._compose_chat()
            with TabPane("⚙️  Settings [F3]", id="tab-settings"):
                yield from self._compose_settings()
        yield Footer()

    def _compose_dashboard(self) -> ComposeResult:
        with Vertical():
            with Horizontal():
                with Container(classes="service-card"):
                    yield Label("Ollama", classes="service-name")
                    yield Label(f"Port: {OLLAMA_PORT}", classes="service-status")
                    yield Label("● Checking…", id="ollama-dot", classes="service-status")
                    with Horizontal(classes="card-btns"):
                        yield Button("▶ Start", id="btn-start-ollama", variant="success")
                        yield Button("■ Stop", id="btn-stop-ollama", variant="error")
                with Container(classes="service-card"):
                    yield Label("ZeroClaw Daemon", classes="service-name")
                    yield Label(f"Port: {ZEROCLAW_PORT}", classes="service-status")
                    yield Label("● Checking…", id="daemon-dot", classes="service-status")
                    with Horizontal(classes="card-btns"):
                        yield Button("Open Browser UI", id="btn-open-browser-ui", variant="primary")
                        yield Button("▶ Start", id="btn-start-daemon", variant="success")
                        yield Button("■ Stop", id="btn-stop-daemon", variant="error")
            yield Rule()
            yield Label("📋 Service Log", classes="service-name")
            yield RichLog(id="dash-log", markup=True, highlight=True, max_lines=200)

    def _compose_chat(self) -> ComposeResult:
        with Vertical():
            yield ScrollableContainer(id="chat-messages")
            yield Label("", id="thinking-bar")
            with Horizontal(id="chat-input-row"):
                yield Input(placeholder="Type a message and press Enter…", id="chat-input")
                yield Button("Send ↵", id="btn-send", variant="primary")

    def _compose_settings(self) -> ComposeResult:
        telegram = get_telegram_settings()
        with Vertical():
            yield Label("⚙️  Configuration", classes="service-name")
            yield Rule()
            with Horizontal(classes="settings-row"):
                yield Label("Model:", classes="settings-label")
                yield Input(value=get_model(), id="input-model")
            with Horizontal(classes="settings-row"):
                yield Label("ZeroClaw Port:", classes="settings-label")
                yield Input(value=str(ZEROCLAW_PORT), id="input-zc-port")
            with Horizontal(classes="settings-row"):
                yield Label("Ollama Port:", classes="settings-label")
                yield Input(value=str(OLLAMA_PORT), id="input-ol-port")
            yield Button("💾 Save Settings", id="btn-save-settings", variant="primary")
            yield Static("", id="settings-status")
            yield Rule()
            yield Label("📨 Telegram Channel", classes="service-name")
            with Horizontal(classes="settings-row"):
                yield Label("Bot Token:", classes="settings-label")
                yield Input(value=str(telegram["bot_token"]), id="input-telegram-token")
            with Horizontal(classes="settings-row"):
                yield Label("Allowed Users:", classes="settings-label")
                yield Input(value=str(telegram["allowed_users"]), id="input-telegram-users")
            with Horizontal(classes="settings-row"):
                yield Label("Bind Identity:", classes="settings-label")
                yield Input(value=str(telegram["bind_identity"]), id="input-telegram-identity")
            yield Button("➕ Add Telegram Channel", id="btn-save-telegram", variant="primary")
            yield Static("", id="telegram-status")
            yield Rule()
            yield Label("🔧 Maintenance", classes="service-name")
            with Horizontal(classes="settings-row"):
                yield Button("Run Auto Setup", id="btn-onboard", variant="default")
                yield Button("Restart All Services", id="btn-restart-all", variant="warning")
                yield Button("Run Self-Test", id="btn-selftest", variant="default")

    # ── Lifecycle ─────────────────────────────────────────────────────

    def on_mount(self):
        self._add_chat_bubble("system",
            "Welcome to **ZeroClaw Control Panel**.  \n"
            "Type a message below to chat with ZeroClaw.  \n"
            "> ℹ️  First response may take 60–120 s while the model loads context.\n"
        )
        # Textual's timer — fires on the event loop, non-blocking
        self.set_interval(5.0, self._poll_status_tick)
        # Run first status poll and onboard check immediately, off main thread
        self.run_worker(self._initial_check, thread=True)

    def on_unmount(self):
        pass  # Textual manages worker lifecycles automatically

    # ── Status polling ────────────────────────────────────────────────

    def _poll_status_tick(self) -> None:
        """Called by Textual's timer on the event loop; dispatches to a thread."""
        self.run_worker(self._status_worker, thread=True,
                        exclusive=True, group="status-poll")

    @work(thread=True)
    def _initial_check(self) -> None:
        """First-run: update status dots AND check if onboarding is needed."""
        ol = is_port_open("127.0.0.1", OLLAMA_PORT)
        dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
        self.call_from_thread(self._update_status, ol, dc)
        status = OnboardStatus()
        if not status.ready:
            self.call_from_thread(self.push_screen, OnboardScreen())

    @work(thread=True)
    def _status_worker(self) -> None:
        """Background worker: poll ports and update status labels."""
        ol = is_port_open("127.0.0.1", OLLAMA_PORT)
        dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
        self.call_from_thread(self._update_status, ol, dc)

    def _update_status(self, ollama: bool, daemon: bool):
        ol_dot = self.query_one("#ollama-dot", Label)
        dc_dot = self.query_one("#daemon-dot", Label)
        ol_dot.update("● Running" if ollama else "● Stopped")
        ol_dot.set_classes("running" if ollama else "stopped")
        dc_dot.update("● Running" if daemon else "● Stopped")
        dc_dot.set_classes("running" if daemon else "stopped")

    # ── Chat helpers ──────────────────────────────────────────────────

    def _add_chat_bubble(self, role: str, content: str):
        container = self.query_one("#chat-messages", ScrollableContainer)
        bubble = ChatBubble(role, content)
        container.mount(bubble)
        container.scroll_end(animate=False)

    def _set_thinking(self, thinking: bool):
        self.thinking = thinking
        bar = self.query_one("#thinking-bar", Label)
        inp = self.query_one("#chat-input", Input)
        btn = self.query_one("#btn-send", Button)
        if thinking:
            bar.update("🤔  ZeroClaw is thinking…  (this may take 60–120 s on first message)")
            inp.disabled = True
            btn.disabled = True
        else:
            bar.update("")
            inp.disabled = False
            btn.disabled = False
            inp.focus()

    # ── Button handlers ───────────────────────────────────────────────

    @on(Button.Pressed, "#btn-send")
    def send_message(self):
        self._do_send()

    @on(Input.Submitted, "#chat-input")
    def input_submitted(self):
        self._do_send()

    def _do_send(self):
        inp = self.query_one("#chat-input", Input)
        msg = inp.value.strip()
        if not msg or self.thinking:
            return
        inp.clear()
        self._add_chat_bubble("user", msg)
        self._set_thinking(True)

        def on_response(resp: str):
            self.call_from_thread(self._add_chat_bubble, "agent", resp)
            self.call_from_thread(self._set_thinking, False)

        def on_error(err: str):
            self.call_from_thread(self._add_chat_bubble, "error",
                                  f"**Error:** {err}")
            self.call_from_thread(self._set_thinking, False)

        self._chat_engine.send(msg, on_response, on_error)

    def _refresh_status(self):
        """Poll ports and update status dots immediately (call from main thread)."""
        def worker():
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-start-ollama")
    def start_ollama(self):
        log = self.query_one("#dash-log", RichLog)
        log.write("[yellow]Starting Ollama…[/]")
        def worker():
            ok = start_ollama()
            self.call_from_thread(log.write,
                f"[{'green' if ok else 'red'}]Ollama {'started' if ok else 'failed'}[/]")
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-stop-ollama")
    def stop_ollama_btn(self):
        log = self.query_one("#dash-log", RichLog)
        log.write("[yellow]Stopping Ollama…[/]")
        def worker():
            msg = stop_ollama()
            self.call_from_thread(log.write, f"[yellow]{msg}[/]")
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-start-daemon")
    def btn_start_daemon(self):
        log = self.query_one("#dash-log", RichLog)
        log.write("[yellow]Starting ZeroClaw daemon…[/]")
        def worker():
            ok, msg = start_daemon()
            self.call_from_thread(log.write,
                f"[{'green' if ok else 'red'}]{msg}[/]")
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-open-browser-ui")
    def btn_open_browser_ui(self):
        log = self.query_one("#dash-log", RichLog)
        if not is_port_open("127.0.0.1", ZEROCLAW_PORT):
            log.write(f"[red]ZeroClaw gateway is not running at http://127.0.0.1:{ZEROCLAW_PORT}/[/]")
            return

        log.write("[yellow]Opening browser dashboard…[/]")

        def worker():
            ok, message = open_gateway_dashboard()
            color = "green" if ok else "red"
            self.call_from_thread(log.write, f"[{color}]{message}[/]")

        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-stop-daemon")
    def btn_stop_daemon(self):
        log = self.query_one("#dash-log", RichLog)
        log.write("[yellow]Stopping ZeroClaw daemon…[/]")
        def worker():
            msg = stop_daemon()
            self.call_from_thread(log.write, f"[yellow]{msg}[/]")
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-save-settings")
    def save_settings(self):
        model = normalize_ollama_model(self.query_one("#input-model", Input).value)
        zc_port = self.query_one("#input-zc-port", Input).value.strip()
        ol_port = self.query_one("#input-ol-port", Input).value.strip()
        status = self.query_one("#settings-status", Static)
        try:
            # Write .env
            env_lines = []
            if ENV_FILE.exists():
                for line in ENV_FILE.read_text().splitlines():
                    k = line.split("=")[0].strip()
                    if k in ("ZEROCLAW_MODEL", "ZEROCLAW_PORT", "OLLAMA_PORT"):
                        continue
                    env_lines.append(line)
            env_lines += [
                f"ZEROCLAW_MODEL={model}",
                f"ZEROCLAW_PORT={zc_port}",
                f"OLLAMA_PORT={ol_port}",
            ]
            ENV_FILE.write_text("\n".join(env_lines) + "\n")
            status.update("✅  Settings saved. Restart services to apply.")
        except Exception as e:
            status.update(f"❌  {e}")

    @on(Button.Pressed, "#btn-save-telegram")
    def save_telegram_channel(self):
        bot_token = self.query_one("#input-telegram-token", Input).value.strip()
        allowed_users = self.query_one("#input-telegram-users", Input).value.strip()
        bind_identity = self.query_one("#input-telegram-identity", Input).value.strip()
        status = self.query_one("#telegram-status", Static)
        log = self.query_one("#dash-log", RichLog)

        if not bot_token:
            status.update("❌  Enter a Telegram bot token.")
            return

        status.update("Configuring Telegram channel…")
        def worker():
            ok, message = configure_telegram_channel_and_bind(bot_token, allowed_users, bind_identity)
            self.call_from_thread(status.update, f"{'✅' if ok else '❌'}  {message}")
            color = "green" if ok else "red"
            self.call_from_thread(log.write, f"[{color}]{message}[/]")
            ol = is_port_open("127.0.0.1", OLLAMA_PORT)
            dc = is_port_open("127.0.0.1", ZEROCLAW_PORT)
            self.call_from_thread(self._update_status, ol, dc)

        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-onboard")
    def re_onboard(self):
        self.push_screen(OnboardScreen())

    @on(Button.Pressed, "#btn-restart-all")
    def restart_all(self):
        log = self.query_one("#dash-log", RichLog)
        log.write("[yellow]Restarting all services…[/]")
        self.query_one("#tabs").active = "tab-dash"
        def worker():
            stop_daemon()
            run(["pkill", "-f", "ollama"])
            time.sleep(1)
            self.call_from_thread(log.write, "▶  Starting Ollama…")
            ok = start_ollama()
            self.call_from_thread(log.write, f"{'✅' if ok else '❌'}  Ollama")
            ok2, msg = pull_model()
            self.call_from_thread(log.write, f"{'✅' if ok2 else '⚠️'} {msg}")
            ensure_zeroclaw_config()
            ok3, msg3 = start_daemon()
            self.call_from_thread(log.write, f"{'✅' if ok3 else '❌'}  {msg3}")
            self.call_from_thread(log.write, "[bold green]Done.[/]")
        threading.Thread(target=worker, daemon=True).start()

    @on(Button.Pressed, "#btn-selftest")
    def run_selftest(self):
        self.push_screen(SelfTestScreen())

    # ── Actions ───────────────────────────────────────────────────────

    def action_clear_chat(self):
        container = self.query_one("#chat-messages", ScrollableContainer)
        container.remove_children()
        self._chat_engine.session_file.unlink(missing_ok=True)
        self._add_chat_bubble("system", "Chat cleared. New session started.")

    def action_tab_dash(self):
        self.query_one("#tabs", TabbedContent).active = "tab-dash"

    def action_tab_chat(self):
        self.query_one("#tabs", TabbedContent).active = "tab-chat"
        self.query_one("#chat-input", Input).focus()

    def action_tab_settings(self):
        self.query_one("#tabs", TabbedContent).active = "tab-settings"


# ---------------------------------------------------------------------------

def main() -> int:
    app = ZeroClawTUI()
    try:
        app.run()
        return 0
    except KeyboardInterrupt:
        return 0
    except asyncio.CancelledError:
        return 0
    except BaseException:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        crash_log = LOG_DIR / "control_tui_crash.log"
        with crash_log.open("a", encoding="utf-8") as handle:
            handle.write("\n=== control_tui crash ===\n")
            traceback.print_exc(file=handle)
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
