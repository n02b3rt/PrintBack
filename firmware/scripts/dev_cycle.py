#!/usr/bin/env python3
"""Build, flash, and capture serial log from the ESP32-C6 in one non-interactive
step - no idf.py monitor (interactive, can't be scripted), just a bounded
serial read that always terminates on its own.

Requires an activated ESP-IDF environment (idf.py on PATH), same as the
Quick start in README.md.

Examples:
    python dev_cycle.py                       # build + flash + 10s capture
    python dev_cycle.py --port COM5 --seconds 30
    python dev_cycle.py --skip-build --skip-flash   # just watch the log
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

FIRMWARE_DIR = Path(__file__).resolve().parent.parent
_ESP_VIDS = {0x303A, 0x10C4, 0x1A86, 0x0403}


def detect_port() -> str | None:
    try:
        from serial.tools import list_ports
    except ImportError:
        return None
    ports = list(list_ports.comports())
    for p in ports:
        if p.vid in _ESP_VIDS:
            return p.device
    return ports[0].device if ports else None


def resolve(cmd: list[str]) -> list[str]:
    """Turn a bare program name into something CreateProcess will actually run.

    On Windows, subprocess with an argument list goes straight to
    CreateProcess, which - unlike the shell - does not consult PATHEXT. So
    "idf.py" matches the literal Python script sitting on PATH, CreateProcess
    is handed a text file and refuses it with "%1 is not a valid Win32
    application" (WinError 193), which is what made this script's build/flash
    path unusable on this machine while typing the same command into
    PowerShell worked fine.

    shutil.which() does apply PATHEXT, so it finds idf.py.exe - the wrapper
    the IDF tools installer puts there. If a platform only has the bare
    script, run it through this interpreter rather than hoping the OS knows
    what to do with it. shell=True would also work, but it would mean quoting
    every path by hand.
    """
    exe = shutil.which(cmd[0])
    if exe is None:
        return cmd  # let subprocess raise the real "not found"
    if exe.lower().endswith(".py"):
        return [sys.executable, exe, *cmd[1:]]
    return [exe, *cmd[1:]]


def run(cmd: list[str]) -> int:
    resolved = resolve(cmd)
    print(f"$ {' '.join(cmd)}")
    return subprocess.call(resolved, cwd=FIRMWARE_DIR)


def capture_serial(port: str, baud: int, seconds: float) -> list[str]:
    import serial

    lines: list[str] = []
    with serial.Serial(port, baud, timeout=1) as ser:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            raw = ser.readline()
            if not raw:
                continue
            line = raw.decode("utf-8", errors="replace").rstrip()
            print(line)
            lines.append(line)
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="COM port; auto-detected via USB VID if omitted")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=10.0, help="how long to capture serial output")
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--skip-flash", action="store_true")
    ap.add_argument("--skip-capture", action="store_true")
    args = ap.parse_args()

    port = args.port or detect_port()
    if not args.skip_flash and not port:
        print("no ESP32 port found/specified, pass --port COMx", file=sys.stderr)
        return 1

    if not args.skip_build:
        rc = run(["idf.py", "build"])
        if rc != 0:
            return rc

    if not args.skip_flash:
        rc = run(["idf.py", "-p", port, "flash"])
        if rc != 0:
            return rc

    if not args.skip_capture:
        if not port:
            print("no port for serial capture, pass --port COMx", file=sys.stderr)
            return 1
        print(f"--- capturing {args.seconds}s of serial on {port} @ {args.baud} ---")
        capture_serial(port, args.baud, args.seconds)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
