#!/usr/bin/env python3.12
"""Quick import test for control_tui.py"""
import sys
import importlib.util

spec = importlib.util.spec_from_file_location(
    "control_tui",
    "/mnt/c/Users/joaqu/ollama-openclaw/scripts/wsl/control_tui.py"
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
