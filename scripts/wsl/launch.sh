#!/bin/bash
set -u
# Launcher script for the Textual TUI — called by start.ps1 via wt.exe.
# Using a script file avoids wt.exe treating ';' as a pane separator.

# On any exit (normal, crash, Ctrl-C) print the exit code.
# The outer "bash -c" wrapper in start.ps1 runs "exec bash -l" afterwards
# to keep the wt.exe tab open regardless.
trap 'echo; echo "--- TUI exited (code $?) ---"' EXIT

# Source login profile so PATH etc. are set up correctly
source /etc/profile 2>/dev/null || true
[ -f /home/joaquin/.profile ] && source /home/joaquin/.profile 2>/dev/null || true
[ -f /home/joaquin/.bashrc ]  && source /home/joaquin/.bashrc  2>/dev/null || true

# Source cargo env (zeroclaw / rustup)
source /home/joaquin/.cargo/env 2>/dev/null || true

# Ensure user-installed binaries (textual, etc.) are on PATH
export PATH="/home/joaquin/.local/bin:/home/joaquin/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO" || {
    echo "Failed to cd to repo: $REPO" >&2
    exit 1
}
ONBOARD_REQUEST_FILE="$REPO/.runtime/request_interactive_onboard"

rm -f "$ONBOARD_REQUEST_FILE"

# Reset terminal in case a previous crashed TUI left it in raw mode
reset 2>/dev/null || tput reset 2>/dev/null || true

# If both services are already up, skip the full setup and go straight to the TUI.
_ol_up() { python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.5); r=s.connect_ex(('127.0.0.1',11434)); s.close(); sys.exit(r)" 2>/dev/null; }
_zc_up() { python3 -c "import socket,sys,os; p=int(os.environ.get('ZEROCLAW_PORT','18789')); s=socket.socket(); s.settimeout(0.5); r=s.connect_ex(('127.0.0.1',p)); s.close(); sys.exit(r)" 2>/dev/null; }

if _ol_up && _zc_up; then
    echo "Both services already running — skipping setup."
else
    # Run setup (starts Ollama + ZeroClaw daemon, patches config)
    "$REPO/scripts/wsl/setup.sh" || true
    # Reset again after setup's progress bars (Ollama pull uses alternate buffer)
    reset 2>/dev/null || tput reset 2>/dev/null || true
fi

while true; do
    # Launch Textual TUI. If it requests interactive onboarding, exit back to
    # the shell, run zeroclaw onboard with full terminal ownership, then restart.
    python3.12 "$REPO/scripts/wsl/control_tui.py"
    tui_status=$?

    if [[ ! -f "$ONBOARD_REQUEST_FILE" ]]; then
        exit "$tui_status"
    fi

    rm -f "$ONBOARD_REQUEST_FILE"
    reset 2>/dev/null || tput reset 2>/dev/null || true

    echo
    echo "============================================================"
    echo "  ZeroClaw Interactive Onboarding"
    echo "  Configure Telegram and any other integrations here."
    echo "============================================================"
    echo

    zeroclaw onboard --config-dir "$REPO/.zeroclaw-home"
    onboard_status=$?

    echo
    if [[ "$onboard_status" -eq 0 ]]; then
        echo "[OK] zeroclaw onboard completed"
    else
        echo "[FAILED] zeroclaw onboard exited $onboard_status"
    fi
    echo "Re-applying config patch and starting services..."

    "$REPO/scripts/wsl/setup.sh" || true
    reset 2>/dev/null || tput reset 2>/dev/null || true
done
