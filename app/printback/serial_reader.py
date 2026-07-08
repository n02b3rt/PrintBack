from __future__ import annotations

import json
import time

import serial
from PySide6.QtCore import QThread, Signal

from . import usb_reset
from .models import Observation

# Firmware emits a heartbeat log line every CONFIG_PRINTBACK_STATS_INTERVAL_SECONDS
# (default 30s) regardless of probe traffic. If the host sees no bytes for
# substantially longer than that, the device or USB stack is hung; close the
# port and let the outer loop reopen it.
_STALE_RECONNECT_SECONDS = 90

# After this many consecutive open failures, attempt a Windows software USB
# reset (pnputil /restart-device). Needs admin to actually succeed.
_USB_RESET_AFTER_FAILS = 3


class SerialReader(QThread):
    observation = Signal(object)
    connection = Signal(bool, str)

    def __init__(self, port: str, baud: int = 115200, parent=None) -> None:
        super().__init__(parent)
        self._port = port
        self._baud = baud
        self._stop = False
        # last time we received *any* bytes from the device (not just parseable
        # JSON). UI watchdog reads this to detect "connected but silent" state.
        self.last_data_at: float = time.time()
        self._consecutive_open_failures = 0
        self._usb_reset_attempted = False

    def stop(self) -> None:
        self._stop = True

    def run(self) -> None:
        while not self._stop:
            try:
                with serial.Serial(self._port, self._baud, timeout=1) as s:
                    self.last_data_at = time.time()
                    self._consecutive_open_failures = 0
                    self._usb_reset_attempted = False
                    self.connection.emit(
                        True, f"connected: {self._port} @ {self._baud}"
                    )
                    self._read_loop(s)
            except (serial.SerialException, OSError) as e:
                self._consecutive_open_failures += 1
                self.connection.emit(False, f"disconnected: {e}")

                if (
                    self._consecutive_open_failures >= _USB_RESET_AFTER_FAILS
                    and not self._usb_reset_attempted
                    and usb_reset.is_supported()
                ):
                    self._usb_reset_attempted = True
                    self.connection.emit(False, "attempting USB software reset…")
                    ok, msg = usb_reset.restart_device(self._port)
                    self.connection.emit(False, f"USB reset: {msg}")
                    if ok:
                        # Wait for re-enumeration (~2-5s typical).
                        for _ in range(60):
                            if self._stop:
                                return
                            self.msleep(100)
                        continue

                # Standard backoff between reconnect attempts.
                for _ in range(20):
                    if self._stop:
                        return
                    self.msleep(100)

    def _read_loop(self, s: serial.Serial) -> None:
        while not self._stop:
            raw = s.readline()
            if not raw:
                if time.time() - self.last_data_at > _STALE_RECONNECT_SECONDS:
                    self.connection.emit(
                        False, "stale port (no data, reconnecting)"
                    )
                    return
                continue
            self.last_data_at = time.time()
            line = raw.decode("utf-8", errors="replace").strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            try:
                obs = Observation.from_json(d, received_at=time.time())
            except (KeyError, ValueError, TypeError):
                continue
            self.observation.emit(obs)
