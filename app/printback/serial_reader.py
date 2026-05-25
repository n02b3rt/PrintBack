from __future__ import annotations

import json
import time

import serial
from PySide6.QtCore import QThread, Signal

from .models import Observation


class SerialReader(QThread):
    observation = Signal(object)
    connection = Signal(bool, str)

    def __init__(self, port: str, baud: int = 115200, parent=None) -> None:
        super().__init__(parent)
        self._port = port
        self._baud = baud
        self._stop = False

    def stop(self) -> None:
        self._stop = True

    def run(self) -> None:
        while not self._stop:
            try:
                with serial.Serial(self._port, self._baud, timeout=1) as s:
                    self.connection.emit(True, f"connected: {self._port} @ {self._baud}")
                    self._read_loop(s)
            except (serial.SerialException, OSError) as e:
                self.connection.emit(False, f"disconnected: {e}")
                for _ in range(20):
                    if self._stop:
                        return
                    self.msleep(100)

    def _read_loop(self, s: serial.Serial) -> None:
        while not self._stop:
            raw = s.readline()
            if not raw:
                continue
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
