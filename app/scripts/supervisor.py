"""Auto-restart wrapper for the PrintBack desktop app.

Run this instead of ``printback`` for unattended deployments. If the app
exits with a non-zero status (crash, unhandled exception, Qt fatal error),
the supervisor waits with exponential backoff and restarts it. Each event
is appended to ``supervisor.log`` next to the SQLite database so the
operator can audit uptime after the fact.

Usage::

    python -m printback.scripts.supervisor          # from inside the venv
    # or directly:
    python scripts/supervisor.py [--port COMx] [--db PATH] ...

All arguments after the script name are forwarded verbatim to printback.
Press Ctrl+C to stop the supervisor (the child app is terminated cleanly).
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

_MIN_BACKOFF = 3
_MAX_BACKOFF = 60
_LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB
_LOG_BACKUPS = 5


def _log_dir() -> Path:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA")
        if base:
            d = Path(base) / "PrintBack"
            d.mkdir(parents=True, exist_ok=True)
            return d
    elif sys.platform == "darwin":
        d = Path.home() / "Library" / "Application Support" / "PrintBack"
        d.mkdir(parents=True, exist_ok=True)
        return d
    xdg = os.environ.get("XDG_DATA_HOME")
    d = Path(xdg) / "PrintBack" if xdg else Path.home() / ".local" / "share" / "PrintBack"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _rotate_log(path: Path) -> None:
    """Manual rotation: keep last N files at supervisor.log.1 .. .N."""
    if not path.exists() or path.stat().st_size < _LOG_MAX_BYTES:
        return
    try:
        # shift .N-1 -> .N, ..., .1 -> .2, drop oldest
        for i in range(_LOG_BACKUPS - 1, 0, -1):
            src = path.with_suffix(f".log.{i}")
            dst = path.with_suffix(f".log.{i + 1}")
            if src.exists():
                if dst.exists():
                    dst.unlink()
                src.rename(dst)
        rotated = path.with_suffix(".log.1")
        if rotated.exists():
            rotated.unlink()
        path.rename(rotated)
    except OSError as e:
        print(f"warning: log rotation failed: {e}", file=sys.stderr)


def _log(line: str) -> None:
    ts = datetime.now().isoformat(timespec="seconds")
    msg = f"[{ts}] supervisor: {line}"
    print(msg, flush=True)
    log_path = _log_dir() / "supervisor.log"
    try:
        _rotate_log(log_path)
        with log_path.open("a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError as e:
        print(f"warning: could not write supervisor.log: {e}", file=sys.stderr)


def main(argv: list[str]) -> int:
    cmd = [sys.executable, "-m", "printback", *argv]
    backoff = _MIN_BACKOFF
    consecutive_crashes = 0
    _log(f"starting supervisor; child cmd = {' '.join(cmd)}")
    while True:
        started_at = time.time()
        _log("launching child")
        try:
            rc = subprocess.call(cmd)
        except KeyboardInterrupt:
            _log("supervisor interrupted by user; exiting")
            return 0
        uptime = time.time() - started_at
        _log(f"child exited rc={rc} after {uptime:.0f}s")

        if rc == 0:
            _log("clean exit; supervisor stopping")
            return 0

        # Reset backoff if the child ran for a meaningful duration before
        # crashing — distinguishes "transient crash" from "broken on launch".
        if uptime > 300:
            backoff = _MIN_BACKOFF
            consecutive_crashes = 0
        else:
            consecutive_crashes += 1

        if consecutive_crashes >= 5:
            _log("5 consecutive fast crashes — likely broken environment; bailing out")
            return 2

        _log(f"restarting in {backoff}s (crash #{consecutive_crashes})")
        try:
            time.sleep(backoff)
        except KeyboardInterrupt:
            _log("supervisor interrupted during backoff; exiting")
            return 0
        backoff = min(backoff * 2, _MAX_BACKOFF)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
