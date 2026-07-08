from __future__ import annotations

import sys
import time
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
from ..i18n import tr
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
        config_path: Path,
        db_path: Path,
        app_dir: Path,
    ) -> None:
        super().__init__()
        self.setWindowTitle("PrintBack")
        self.resize(1320, 820)

        self.config = config
        self.config_path = config_path
        self.app_dir = app_dir
        self.store = Store(db_path)
        self._verify_store_integrity()
        self.maintenance = Maintenance(self.store, self.config, app_dir)

        # connection state, used to render status bar with stale-detection
        self._conn_ok = False
        self._conn_msg = tr("status.connecting")

        self._build_ui(db_path)
        self.setStyleSheet(theme.QSS)

        try:
            self.maintenance.run_all()
        except Exception as e:  # noqa: BLE001
            print(f"warning: startup maintenance failed: {e}", file=sys.stderr)

        self.reader = SerialReader(port, config.serial_baud, parent=self)
        self.reader.observation.connect(self._on_observation)
        self.reader.connection.connect(self._on_connection)
        self.reader.start()

        self.whitelist_panel.refresh()
        self.stats_tab.refresh_slow()
        self.debug_tab.refresh_slow()

        self._fast = QTimer(self)
        self._fast.setInterval(1000)
        self._fast.timeout.connect(self._tick_fast)
        self._fast.start()

        self._slow = QTimer(self)
        self._slow.setInterval(10_000)
        self._slow.timeout.connect(self._tick_slow)
        self._slow.start()

        self._maint = QTimer(self)
        self._maint.setInterval(self.config.maintenance_interval_minutes * 60_000)
        self._maint.timeout.connect(self._run_maintenance_quiet)
        self._maint.start()

    def _build_ui(self, db_path: Path) -> None:
        splitter = QSplitter(Qt.Orientation.Horizontal, self)

        self.tabs = QTabWidget()
        self.stats_tab = StatsTab(self.store, self.config)
        self.debug_tab = DebugTab(self.store, self.config)
        self.tabs.addTab(self.stats_tab, tr("tab.stats"))
        self.tabs.addTab(self.debug_tab, tr("tab.debug"))
        splitter.addWidget(self.tabs)

        self.whitelist_panel = WhitelistPanel(self.store)
        splitter.addWidget(self.whitelist_panel)

        splitter.setStretchFactor(0, 4)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([1000, 320])
        self.setCentralWidget(splitter)

        self.setStatusBar(QStatusBar(self))
        self.status_conn = QLabel(tr("status.connecting"))
        self.statusBar().addWidget(self.status_conn)
        db_label = QLabel(tr("status.db", path=str(db_path)))
        db_label.setStyleSheet(f"color: {theme.MUTED};")
        self.statusBar().addPermanentWidget(db_label)

    def _on_connection(self, ok: bool, msg: str) -> None:
        self._conn_ok = ok
        self._conn_msg = msg
        self._apply_status()

    def _apply_status(self) -> None:
        if not self._conn_ok:
            self.status_conn.setText(self._conn_msg)
            self.status_conn.setStyleSheet(f"color: {theme.BAD};")
            self.setWindowTitle("PrintBack")
            return
        age = time.time() - self.reader.last_data_at
        if age > 45:
            self.status_conn.setText(
                tr("status.stale", base=self._conn_msg, age=int(age))
            )
            self.status_conn.setStyleSheet(f"color: {theme.WARN};")
            self.setWindowTitle("PrintBack: NO DATA")
        else:
            self.status_conn.setText(self._conn_msg)
            self.status_conn.setStyleSheet(f"color: {theme.OK};")
            self.setWindowTitle("PrintBack")

    def _on_observation(self, obs: Observation) -> None:
        self.store.insert(obs)
        self.store.commit()
        if obs.whitelisted and self.store.remember_whitelisted(obs.fp, source="device"):
            self.whitelist_panel.refresh()
        self.stats_tab.on_observation(obs)
        self.debug_tab.on_observation(obs)

    def _verify_store_integrity(self) -> None:
        """On startup, run PRAGMA integrity_check. If the DB is corrupt, move
        it aside and restore from the most recent backup. Logs to stderr; the
        excepthook captures persistent errors elsewhere."""
        if self.store.integrity_check():
            return
        print(f"warning: SQLite integrity check FAILED for {self.store.path}",
              file=sys.stderr)
        import shutil
        backups_dir = self.app_dir / "backups"
        candidates = sorted(backups_dir.glob("printback-*.db")) if backups_dir.exists() else []
        if not candidates:
            print("no backups available, leaving DB as-is (writes may fail)",
                  file=sys.stderr)
            return
        latest = candidates[-1]
        corrupt = self.store.path.with_suffix(".db.corrupt")
        try:
            self.store.conn.close()
            if corrupt.exists():
                corrupt.unlink()
            self.store.path.replace(corrupt)
            shutil.copy(latest, self.store.path)
            self.store.reopen()
            print(f"restored DB from backup: {latest.name} "
                  f"(corrupt DB saved as {corrupt.name})", file=sys.stderr)
        except OSError as e:
            print(f"backup restore failed: {e}", file=sys.stderr)

    def _tick_fast(self) -> None:
        try:
            self.stats_tab.tick()
            self.debug_tab.tick()
            self._apply_status()
        except Exception as e:  # noqa: BLE001
            print(f"tick_fast error: {e}", file=sys.stderr)

    def _tick_slow(self) -> None:
        try:
            self.stats_tab.refresh_slow()
            self.debug_tab.refresh_slow()
        except Exception as e:  # noqa: BLE001
            print(f"tick_slow error: {e}", file=sys.stderr)

    def _run_maintenance_quiet(self) -> None:
        try:
            report = self.maintenance.run_all()
            if report.auto_wl_added or report.aggregated_days:
                self.whitelist_panel.refresh()
                self.stats_tab.refresh_slow()
        except Exception as e:  # noqa: BLE001
            print(f"maintenance error: {e}", file=sys.stderr)

    def closeEvent(self, event: QCloseEvent) -> None:
        self._fast.stop()
        self._slow.stop()
        self._maint.stop()
        self.reader.stop()
        self.reader.wait(2000)
        self.store.close()
        super().closeEvent(event)
