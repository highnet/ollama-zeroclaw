# ZeroClaw + Ollama Local Control Panel

This repository turns ZeroClaw into a repo-local, Windows-friendly local agent stack backed by Ollama. It provides:

- Windows entrypoint scripts for setup, start, stop, and status.
- WSL automation that prepares ZeroClaw, patches config, starts services, and keeps runtime state inside this repo.
- A Textual-based terminal control panel with onboarding, service controls, chat, settings, and self-test.
- Optional Telegram channel configuration and binding.
- Helper scripts for validation, debugging, and regression testing.

The goal is a local-first ZeroClaw install you can run, inspect, and remove without chasing state across your machine.

## What This Repo Offers

### Core workflow

- One-command setup from Windows with `setup.ps1`.
- One-command launch into the TUI with `start.ps1` or `start.bat`.
- Repo-local ZeroClaw config and state in `.zeroclaw-home/`.
- Repo-local runtime metadata in `.runtime/`.
- Repo-local logs in `logs/`.
- Automatic model pull for the configured Ollama model.
- Automatic daemon startup for ZeroClaw.
- A browser-accessible ZeroClaw gateway UI on the configured port.

### Runtime behavior

- Prefers Windows Ollama at `http://localhost:11434` for GPU acceleration when available.
- Falls back to WSL Ollama when Windows Ollama is not listening.
- Starts the ZeroClaw daemon on `ZEROCLAW_PORT` with host `0.0.0.0`.
- Auto-generates and patches ZeroClaw config for this repo.
- Keeps chat session state in `.runtime/session.json`.
- Rebuilds the ZeroClaw web dashboard from installed source when those web assets are available in the Cargo registry.

### Control panel features

The TUI in `scripts/wsl/control_tui.py` includes:

- Automatic onboarding wizard when dependencies or services are missing.
- Dashboard tab with live service state for Ollama and ZeroClaw.
- Start and stop buttons for Ollama and the ZeroClaw daemon.
- `Open Browser UI` button to launch the gateway dashboard in a browser.
- Chat tab that sends one-shot ZeroClaw agent prompts with session persistence.
- Settings tab for model, ZeroClaw port, Ollama port, and Telegram channel settings.
- `Run Auto Setup`, `Restart All Services`, and `Run Self-Test` maintenance actions.
- Keyboard shortcuts: `F1` dashboard, `F2` chat, `F3` settings, `Ctrl+L` clear chat, `Ctrl+Q` quit.

### Telegram support

The repo supports configuring a Telegram channel in ZeroClaw's current config schema:

- Stores Telegram settings under `[channels_config.telegram]` in `.zeroclaw-home/config.toml`.
- Supports bot token, allowed users, bind identity, `mention_only`, and `interrupt_on_new_message`.
- Can bind a Telegram identity with `zeroclaw channel bind-telegram <IDENTITY>`.
- Applies channel config updates by restarting the daemon from the TUI workflow.

## Recommended Architecture

This repo is built around a mixed Windows + WSL setup:

1. Windows launches the wrapper scripts.
2. WSL hosts the ZeroClaw CLI, config, daemon, and TUI runtime.
3. Windows Ollama is preferred for GPU-backed inference when installed.
4. WSL talks to Windows Ollama through mirrored localhost networking.
5. If Windows Ollama is unavailable, WSL can run `ollama serve` as a CPU fallback.

That means you get Windows-native launching and browser opening, while keeping ZeroClaw runtime files inside the repo and Linux tooling inside WSL.

## Repo Layout

```text
.
|-- README.md
|-- setup.ps1
|-- start.ps1
|-- start.bat
|-- stop.ps1
|-- status.ps1
|-- logs/
|-- scripts/
|   |-- check_schema.py
|   |-- install_pip.sh
|   |-- restart_daemon.sh
|   |-- test_agent.sh
|   |-- test_agent2.sh
|   |-- test_agent3.sh
|   |-- test_agent4.sh
|   |-- test_import.py
|   |-- test_linux_nosandbox.sh
|   |-- test_linux_path.sh
|   |-- test_ollama.py
|   |-- windows/
|   |   `-- localhost_proxy.py
|   `-- wsl/
|       |-- common.sh
|       |-- control_tui.py
|       |-- keep_open.sh
|       |-- launch.sh
|       |-- setup.sh
|       |-- start.sh
|       |-- status.sh
|       |-- stop.sh
|       `-- tui.sh
|-- .env.example
|-- .runtime/
`-- .zeroclaw-home/
```

### Important runtime directories

- `.zeroclaw-home/`: repo-local ZeroClaw config directory.
- `.runtime/`: PID files and chat session state.
- `logs/`: daemon logs, Ollama logs, crash logs, and validation artifacts.

## Prerequisites

### Windows

- Windows with PowerShell.
- WSL2 installed.
- A usable WSL distro, preferably `Ubuntu-24.04` or another Ubuntu distro.
- Windows Terminal is recommended, but not required.

### WSL

The repo assumes native Linux binaries inside WSL for:

- `python3`
- `zeroclaw`
- `ollama`

The scripts intentionally reject Windows binaries inherited into WSL through `/mnt/c/...` on `PATH`.

### Optional but preferred

- Windows Ollama installed at `%LOCALAPPDATA%\Programs\Ollama\ollama.exe` for GPU acceleration.
- `npm` inside WSL if you want the web dashboard rebuilt from the installed ZeroClaw package sources.
- `textual` available to the WSL Python interpreter for the TUI.

## Quick Start

From PowerShell in the repo root:

```powershell
./setup.ps1
./start.ps1
./status.ps1
```

Or double-click `start.bat` from Explorer.

What happens:

1. `setup.ps1` enters WSL and runs `scripts/wsl/setup.sh`.
2. The WSL setup script creates `.env` from `.env.example` if needed.
3. It sets up repo-local ZeroClaw state in `.zeroclaw-home/`.
4. It prefers Windows Ollama, or starts WSL Ollama if needed.
5. It pulls the configured model if missing.
6. It builds the ZeroClaw web dashboard if the package web sources are available.
7. It patches ZeroClaw config to match this repo's expectations.
8. It starts the ZeroClaw daemon.
9. `start.ps1` launches the TUI in a new Windows Terminal tab or a WSL fallback process.

## Main Entry Points

### Windows wrappers

| File | Purpose |
|---|---|
| `setup.ps1` | Runs the WSL setup script from Windows. |
| `start.ps1` | Starts Windows Ollama if present, then opens the WSL TUI launcher. |
| `start.bat` | Explorer-friendly wrapper around `start.ps1`. |
| `stop.ps1` | Stops WSL `zeroclaw` and WSL `ollama` processes and removes runtime PID files. |
| `status.ps1` | Reports repo path, ZeroClaw home, configured model, service reachability, and installed models. |

### WSL lifecycle scripts

| File | Purpose |
|---|---|
| `scripts/wsl/setup.sh` | Full setup: env bootstrap, config patching, model pull, optional dashboard build, daemon start. |
| `scripts/wsl/start.sh` | Lightweight ready-check setup for TUI use. |
| `scripts/wsl/status.sh` | Native WSL status output for service and config checks. |
| `scripts/wsl/stop.sh` | Stops daemon and any repo-tracked WSL Ollama instance. |
| `scripts/wsl/tui.sh` | Ensures setup and then executes the Python TUI directly. |
| `scripts/wsl/launch.sh` | Launcher used by Windows wrappers; runs setup if needed and starts the TUI. |
| `scripts/wsl/keep_open.sh` | Wrapper that keeps the terminal tab open after TUI exit. |
| `scripts/wsl/common.sh` | Shared paths, env loading, helper functions, PID management, and port checks. |

## TUI Walkthrough

### Dashboard

The dashboard tab shows:

- Ollama port and running/stopped status.
- ZeroClaw daemon port and running/stopped status.
- Buttons to start and stop each service.
- A log pane for service actions.
- A browser launch action for the ZeroClaw gateway UI.

### Chat

The chat tab:

- Sends prompts through `zeroclaw agent -m`.
- Uses `.runtime/session.json` as a persistent session-state file.
- Preserves context across messages within the repo-local session.
- Uses `TERM=dumb` and `NO_COLOR=1` so terminal escape sequences do not corrupt output parsing.
- Applies a 300 second timeout to chat requests.

The first response may be noticeably slower while the model warms up.

### Settings

The settings tab can save:

- `ZEROCLAW_MODEL`
- `ZEROCLAW_PORT`
- `OLLAMA_PORT`
- Telegram bot token
- Telegram allowed users
- Telegram bind identity

Saving model and port settings writes `.env`. Restart services after saving for the changes to apply.

### Maintenance actions

The TUI also exposes:

- `Run Auto Setup`: reruns the onboarding setup flow.
- `Restart All Services`: cycles Ollama and the daemon from the UI.
- `Run Self-Test`: runs `zeroclaw self-test --config-dir .zeroclaw-home` and shows the output in a dedicated screen.

## Configuration

### `.env`

This repo reads `.env` from the repo root. If it does not exist, setup copies `.env.example`.

Current defaults:

```env
ZEROCLAW_MODEL=ollama/qwen2.5:1.5b
ZEROCLAW_PORT=18789
```

Additional values may be written by the TUI:

```env
OLLAMA_PORT=11434
ZEROCLAW_TELEGRAM_IDENTITY=<username-or-id>
```

### ZeroClaw config patching

The setup and TUI flows patch `.zeroclaw-home/config.toml` to enforce the repo's expected behavior:

- Gateway port matches `ZEROCLAW_PORT`.
- `require_pairing = false`.
- Sandbox backend is forced to `none`.
- Legacy `[channels]` config is migrated into `[channels_config]` when needed.
- Telegram settings are written into `[channels_config.telegram]`.

The setup flow also ensures a usable auth token exists and preserves everything inside the repo-local config dir.

## Model Guidance

Recommended default:

- `ollama/qwen2.5:1.5b`

Reasonable upgrade:

- `ollama/llama3.2:3b`

Use caution on lower-memory systems:

- 7B+ models
- vision-heavy models
- multiple concurrent local model processes

Change the model by editing `.env` or using the TUI settings tab, then restart services.

## Telegram Setup

You can configure Telegram from the TUI or manually.

### Through the TUI

1. Open the `Settings` tab.
2. Fill in `Bot Token`.
3. Set `Allowed Users` as a comma-separated list, or `*`.
4. Optionally set `Bind Identity` to a Telegram numeric ID or username without `@`.
5. Click `Add Telegram Channel`.

The TUI will:

- write the Telegram config into `.zeroclaw-home/config.toml`
- restart the daemon
- optionally run `zeroclaw channel bind-telegram <IDENTITY>`

### Manual config details

Minimal Telegram config fields supported by this repo:

- `bot_token`
- `allowed_users`
- `stream_mode`
- `mention_only`
- `interrupt_on_new_message`

## Browser Dashboard

When the daemon is running, the ZeroClaw gateway UI is available at:

```text
http://localhost:18789/
```

If you change `ZEROCLAW_PORT`, use that port instead.

The TUI's `Open Browser UI` button opens the gateway URL directly. Using `localhost` consistently is preferred so browser auth and device state do not split across `localhost` and `127.0.0.1`.

## Utility and Test Scripts

This repo includes several support scripts for validation and debugging.

### General utilities

| File | Purpose |
|---|---|
| `scripts/check_schema.py` | Dumps relevant keys from ZeroClaw's config schema for inspection. |
| `scripts/install_pip.sh` | Bootstraps `pip` and installs `textual` in WSL. |
| `scripts/restart_daemon.sh` | Manual daemon restart plus health checks. |
| `scripts/windows/localhost_proxy.py` | Async TCP forwarder for localhost-to-target proxying. |

### Validation and debugging scripts

| File | Purpose |
|---|---|
| `scripts/test_ollama.py` | Checks Ollama health and performs a direct generate request. |
| `scripts/test_import.py` | Verifies `control_tui.py` imports cleanly. |
| `scripts/test_agent.sh` | Runs a sandbox-disabled ZeroClaw agent test from a temp config. |
| `scripts/test_agent2.sh` | Captures verbose agent startup output into a temp log. |
| `scripts/test_agent3.sh` | Runs an agent prompt against the repo config and compares daemon log output. |
| `scripts/test_agent4.sh` | Similar repo-level agent test with log slicing. |
| `scripts/test_linux_path.sh` | Tests agent execution from a Linux-native config path. |
| `scripts/test_linux_nosandbox.sh` | Linux-native config path test with sandbox explicitly forced to `none`. |

These scripts are primarily for maintenance and debugging, not for the main end-user flow.

## Logs and Diagnostics

Common runtime files:

- `logs/ollama.log`
- `logs/zeroclaw.log`
- `logs/control_tui_crash.log`
- `.runtime/ollama.pid`
- `.runtime/zeroclaw.pid`
- `.runtime/session.json`

The `logs/` directory also contains historical validation artifacts captured during bring-up and troubleshooting.

## Common Commands

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

## Known Behaviors and Troubleshooting

### TUI exits but the wrapper stays open

This is intentional. `scripts/wsl/keep_open.sh` keeps the terminal tab alive after the TUI exits so you can inspect messages.

### Launcher prints a nonzero exit code after the TUI appeared normal

The launcher compensates for a case where Textual teardown can return `1` even after a normal exit. `scripts/wsl/launch.sh` treats that as success unless a new crash log entry was written.

### Browser UI reply or pairing problems

If the browser UI starts failing to reply, stale repo-local device pairing state may be the cause. Clearing `.openclaw-home/devices/paired.json` and restarting can reset device auth. Use `localhost` consistently in the browser URL to avoid splitting auth state.

### Windows `stop.ps1` does not kill Windows Ollama

`stop.ps1` stops WSL `zeroclaw` and WSL `ollama`. The TUI stop action is broader and also attempts to stop Windows Ollama.

### WSL command resolves to a Windows binary

The shell helpers reject commands resolved under `/mnt/c/...`. Install native Linux versions of `python3`, `ollama`, and `zeroclaw` inside WSL.

### Model pull is slow

That is expected on first run or with larger models. The onboarding screen streams pull output so you can see progress.

### The daemon starts but chat is slow or times out

The chat flow allows up to 300 seconds. On small systems, first-token latency can still be high during warmup or under CPU fallback.

## Why This Repo Is Useful

This repo is more than a thin launcher. It gives you:

- a repo-contained ZeroClaw environment
- Windows and WSL orchestration already wired together
- automatic onboarding and config repair
- a practical local control panel instead of raw CLI only
- optional Telegram integration
- bundled validation scripts for debugging and regression checks

If you want a local ZeroClaw stack that is inspectable, reproducible, and easy to start from Windows while keeping the actual runtime under WSL, this repository already has that surface area built in.
