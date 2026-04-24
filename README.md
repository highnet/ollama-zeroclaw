# ZeroClaw + Ollama Local TUI Setup

This repository gives you a local ZeroClaw AI agent setup backed by Ollama, with scripts for Windows and WSL2 that launch a terminal-based UI (TUI).

## Recommended architecture

- Run Ollama inside WSL2 Ubuntu.
- Run ZeroClaw as a daemon inside WSL2, exposing a local API.
- Launch the ZeroClaw TUI from Windows, which opens a new terminal running the ZeroClaw agent loop.

## What this repo creates

- A repo-local ZeroClaw home at `.zeroclaw-home/`
- Background logs in `logs/`
- Runtime PID files in `.runtime/`
- Windows wrappers: `setup.ps1`, `start.ps1`, `stop.ps1`, `status.ps1`
- WSL scripts under `scripts/wsl/`

## Memory guidance

Recommended default:

- `ollama/qwen2.5:1.5b` (small, tool-capable)

Good alternatives:

- `llama3.2:3b`

Avoid on 8 GB system RAM unless you accept a much slower experience:

- 7B and larger models
- vision-heavy models
- multiple concurrent local model processes

## Prerequisites

On Windows:

- WSL2 installed
- Ubuntu installed in WSL2
- PowerShell

Inside WSL2, the setup script will install if missing:

- `curl`
- Node.js 24
- `zeroclaw` CLI
- `ollama`

## Quick start

From this repository in PowerShell:

```powershell
./setup.ps1
./start.ps1
./status.ps1
```

Then a new terminal window will open with the ZeroClaw TUI running.

## Change the model

Edit `.env` in the repo root and set:

```env
ZEROCLAY_MODEL=ollama/llama3.2:3b
```

Then rerun:

```powershell
./setup.ps1
./start.ps1
```

## Notes

- The setup is intentionally local-first and does not configure external messaging channels.
- The scripts keep ZeroClaw state inside this repository so you can delete the repo without hunting for config elsewhere.
- The TUI is launched in a new Windows terminal via `wt.exe` (Windows Terminal) or `wsl` fallback.
