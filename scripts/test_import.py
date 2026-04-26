#!/usr/bin/env python3.12
"""Quick import test for control_tui.py"""
import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CONTROL_TUI_PATH = REPO_ROOT / "scripts" / "wsl" / "control_tui.py"

spec = importlib.util.spec_from_file_location(
    "control_tui",
    CONTROL_TUI_PATH
)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
    print("OK: imports successful")
except SystemExit:
    print("OK: app tried to init (expected)")
except Exception as e:
    print(f"ERROR: {e}")
    import traceback; traceback.print_exc()
