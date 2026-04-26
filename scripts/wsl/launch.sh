#!/bin/bash
set -u
# Launcher script for the Textual TUI — called by start.ps1 via wt.exe.
# Using a script file avoids wt.exe treating ';' as a pane separator.

# On any exit (normal, crash, Ctrl-C) print the real exit code.
# The outer wrapper keeps the terminal open afterwards.
trap 'rc=$?; echo; echo "--- TUI exited (code $rc) ---"' EXIT

# Source login files with nounset disabled because distro/user profiles often
# assume interactive shells and may reference unset variables.
set +u
source /etc/profile 2>/dev/null || true
[ -f /home/joaquin/.profile ] && source /home/joaquin/.profile 2>/dev/null || true
[ -f /home/joaquin/.bashrc ]  && source /home/joaquin/.bashrc  2>/dev/null || true
set -u

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
CRASH_LOG="$REPO/logs/control_tui_crash.log"

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

crash_log_size=0
if [[ -f "$CRASH_LOG" ]]; then
    crash_log_size=$(wc -c < "$CRASH_LOG")
fi

python3.12 "$REPO/scripts/wsl/control_tui.py"
tui_status=$?
crash_logged=0
if [[ -f "$CRASH_LOG" ]]; then
    current_crash_log_size=$(wc -c < "$CRASH_LOG")
    if (( current_crash_log_size > crash_log_size )); then
        crash_logged=1
    fi
fi

if [[ "$tui_status" -eq 1 && "$crash_logged" -eq 0 ]]; then
    # Textual occasionally returns 1 on a normal terminal teardown even
    # though the app did not crash. Keep actual logged failures nonzero.
    exit 0
fi

exit "$tui_status"
