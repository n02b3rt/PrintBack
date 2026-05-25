from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from PySide6.QtWidgets import QApplication

from .ui.main_window import MainWindow

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


def main() -> int:
    ap = argparse.ArgumentParser(prog="printback")
    ap.add_argument(
        "--port",
        default=os.environ.get("PRINTBACK_SERIAL_PORT"),
        help="serial port (default: auto-detect; env: PRINTBACK_SERIAL_PORT)",
    )
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--db", type=Path, default=Path("printback.db"))
    args = ap.parse_args()

    port = args.port or detect_port()
    if port is None:
        print(
            "no serial port detected. pass --port COMx or set PRINTBACK_SERIAL_PORT",
            file=sys.stderr,
        )
        return 2

    app = QApplication(sys.argv)
    win = MainWindow(port=port, baud=args.baud, db_path=args.db)
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
