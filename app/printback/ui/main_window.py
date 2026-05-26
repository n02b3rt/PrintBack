from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QCloseEvent
from PySide6.QtWidgets import (
    QLabel,
    QMainWindow,
    QSplitter,
    QStatusBar,
    QTabWidget,
)

from ..config import Config
from ..maintenance import Maintenance
from ..models import Observation
from ..serial_reader import SerialReader
from ..store import Store
from . import theme
from .debug_tab import DebugTab
from .stats_tab import StatsTab
from .whitelist_panel import WhitelistPanel


class MainWindow(QMainWindow):
    def __init__(
        self,
        port: str,
        config: Config,
        db_path: Path,
        app_dir: Path,
    ) -> None:
        super().__init__()
        self.setWindowTitle("PrintBack")
        self.resize(1320, 820)

        self.config = config
        self.app_dir = app_dir
        self.store = Store(db_path)
        self.maintenance = Maintenance(self.store, self.config, app_dir)

        self._build_ui(db_path)
        self.setStyleSheet(theme.QSS)

        # Catch-up maintenance on startup (covers offline periods).
        try:
            report = self.maintenance.run_all()
            if report.has_changes():
                # WL panel doesn't exist yet at construction; will refresh below.
                pass
        except Exception as e:  # noqa: BLE001
            print(f"warning: startup maintenance failed: {e}", file=sys.stderr)

        # Serial reader
        self.reader = SerialReader(port, config.serial_baud, parent=self)
        self.reader.observation.connect(self._on_observation)
        self.reader.connection.connect(self._on_connection)
        self.reader.start()

        # Initial UI population
        self.whitelist_panel.refresh()
        self.stats_tab.refresh_slow()
        self.debug_tab.refresh_slow()

        # Fast tick (1 Hz): KPIs, live RSSI, raw log scroll
        self._fast = QTimer(self)
        self._fast.setInterval(1000)
        self._fast.timeout.connect(self._tick_fast)
        self._fast.start()

        # Slow refresh (DB queries): every 10s
        self._slow = QTimer(self)
        self._slow.setInterval(10_000)
        self._slow.timeout.connect(self._tick_slow)
        self._slow.start()

        # Maintenance loop
        self._maint = QTimer(self)
        self._maint.setInterval(self.config.maintenance_interval_minutes * 60_000)
        self._maint.timeout.connect(self._run_maintenance_quiet)
        self._maint.start()

    def _build_ui(self, db_path: Path) -> None:
        splitter = QSplitter(Qt.Orientation.Horizontal, self)

        self.tabs = QTabWidget()
        self.stats_tab = StatsTab(self.store, self.config)
        self.debug_tab = DebugTab(self.store, self.config)
        self.tabs.addTab(self.stats_tab, "Statystyki")
        self.tabs.addTab(self.debug_tab, "Debug")
        splitter.addWidget(self.tabs)

        self.whitelist_panel = WhitelistPanel(self.store)
        splitter.addWidget(self.whitelist_panel)

        splitter.setStretchFactor(0, 4)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([1000, 320])
        self.setCentralWidget(splitter)

        self.setStatusBar(QStatusBar(self))
        self.status_conn = QLabel("łączenie…")
        self.statusBar().addWidget(self.status_conn)
        db_label = QLabel(f"db: {db_path}")
        db_label.setStyleSheet(f"color: {theme.MUTED};")
        self.statusBar().addPermanentWidget(db_label)

    # ---------- signal handlers ----------

    def _on_connection(self, ok: bool, msg: str) -> None:
        self.status_conn.setText(msg)
        color = theme.OK if ok else theme.BAD
        self.status_conn.setStyleSheet(f"color: {color};")

    def _on_observation(self, obs: Observation) -> None:
        self.store.insert(obs)
        self.store.commit()
        if obs.whitelisted and self.store.remember_whitelisted(obs.fp, source="device"):
            self.whitelist_panel.refresh()
        self.stats_tab.on_observation(obs)
        self.debug_tab.on_observation(obs)

    # ---------- timers ----------

    def _tick_fast(self) -> None:
        self.stats_tab.tick()
        self.debug_tab.tick()

    def _tick_slow(self) -> None:
        self.stats_tab.refresh_slow()
        self.debug_tab.refresh_slow()

    def _run_maintenance_quiet(self) -> None:
        try:
            report = self.maintenance.run_all()
            if report.auto_wl_added or report.aggregated_days:
                self.whitelist_panel.refresh()
                self.stats_tab.refresh_slow()
        except Exception as e:  # noqa: BLE001
            print(f"maintenance error: {e}", file=sys.stderr)

    def closeEvent(self, event: QCloseEvent) -> None:
        self.reader.stop()
        self.reader.wait(2000)
        self.store.close()
        super().closeEvent(event)
