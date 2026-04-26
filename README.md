# ZeroClaw + Ollama Local Control Panel

This repo gives you a Windows-friendly way to run ZeroClaw locally with Ollama.

The intended setup is simple:

- Windows launches the wrapper scripts.
- WSL runs ZeroClaw, the daemon, and the TUI.
- Windows Ollama is preferred when available.
- Repo-local state stays inside this repo.

## What You Get

- `setup.ps1` and `setup.bat` for first-time setup
- `start.ps1` and `start.bat` to launch the control panel
- `status.ps1` and `stop.ps1` for basic lifecycle control
- a terminal UI for setup, chat, service control, settings, and self-test
- repo-local config, logs, session state, and runtime files
- optional Telegram channel configuration

## Requirements

### Windows

- PowerShell
- WSL2
- a working Ubuntu-based WSL distro

### Inside WSL

- `python3`
- `zeroclaw`
- `ollama`

### Nice to have

- Windows Ollama installed for GPU-backed inference
- `textual` available in the WSL Python environment
- `npm` in WSL if you want the ZeroClaw web dashboard rebuilt from installed package assets

## Quick Start

From PowerShell in the repo root:

```powershell
./setup.ps1
./start.ps1
./status.ps1
```

From Explorer:

- run `setup.bat` once
- run `start.bat` to launch the control panel

## What Setup Does

`setup.ps1` enters WSL and runs the repo setup flow. That flow:

- creates `.env` from `.env.example` if needed
- prepares `.zeroclaw-home/` for repo-local ZeroClaw config
- starts or connects to Ollama
- pulls the configured model if needed
- patches ZeroClaw config for this repo
- starts the ZeroClaw daemon
- stores runtime data under `.runtime/` and logs under `logs/`

## Main Commands

### Windows

```powershell
./setup.ps1
./start.ps1
./status.ps1
./stop.ps1
```

### WSL

```bash
./scripts/wsl/setup.sh
./scripts/wsl/status.sh
./scripts/wsl/stop.sh
./scripts/wsl/tui.sh
```

## TUI Overview

The control panel includes:

- a dashboard with Ollama and ZeroClaw status
- buttons to start and stop services
- a chat tab that uses repo-local session state
- a settings tab for model, ports, and Telegram settings
- self-test and restart actions

Keyboard shortcuts:

- `F1` dashboard
- `F2` chat
- `F3` settings
- `Ctrl+L` clear chat
- `Ctrl+Q` quit

## Configuration

This repo reads `.env` from the repo root.

Default values:

```env
ZEROCLAW_MODEL=ollama/qwen2.5:1.5b
ZEROCLAW_PORT=18789
```

The TUI may also write:

```env
OLLAMA_PORT=11434
ZEROCLAW_TELEGRAM_IDENTITY=<username-or-id>
```

The setup flow patches `.zeroclaw-home/config.toml` so the repo uses the expected port, disables pairing, forces sandbox backend `none`, and keeps Telegram settings in the current config schema.

## Browser UI

When the daemon is running, the ZeroClaw gateway is available at:

```text
http://localhost:18789/
```

If you change `ZEROCLAW_PORT`, use that port instead.

## Local State

Most machine-specific state lives here:

- `.zeroclaw-home/` for ZeroClaw config
- `.runtime/` for PID files and session state
- `logs/` for daemon, Ollama, and crash logs

If you move this repo to another machine, run setup again.

## Telegram

You can configure Telegram from the TUI.

Supported settings include:

- bot token
- allowed users
- bind identity
- `mention_only`
- `interrupt_on_new_message`

## Troubleshooting

### The TUI closes but the terminal stays open

That is intentional. The wrapper keeps the terminal open so you can read errors or exit messages.

### `stop.ps1` does not stop Windows Ollama

That script stops WSL services. If Windows Ollama is running separately, stop it from Windows.

### WSL is picking up a Windows binary

Install native Linux versions of `python3`, `ollama`, and `zeroclaw` in WSL. The helper scripts intentionally reject `/mnt/c/...` binaries.

### First run is slow

Model pull and first model warmup can take a while, especially on CPU fallback.

### Chat feels slow or times out

The first response can be much slower than later ones, especially on lower-memory systems or when Windows Ollama is unavailable.
