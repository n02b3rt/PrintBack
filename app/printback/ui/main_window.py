from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction, QActionGroup, QCloseEvent
from PySide6.QtWidgets import (
    QLabel,
    QMainWindow,
    QMessageBox,
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
        self.maintenance = Maintenance(self.store, self.config, app_dir)

        self._build_ui(db_path)
        self._build_menu()
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

    def _build_menu(self) -> None:
        menu_bar = self.menuBar()
        settings_menu = menu_bar.addMenu(tr("menu.settings"))
        language_menu = settings_menu.addMenu(tr("menu.language"))

        group = QActionGroup(self)
        group.setExclusive(True)

        for locale_code, label_key in (("pl", "menu.language.pl"),
                                       ("en", "menu.language.en")):
            act = QAction(tr(label_key), self, checkable=True)
            act.setData(locale_code)
            act.setChecked(self.config.locale == locale_code)
            group.addAction(act)
            language_menu.addAction(act)

        group.triggered.connect(self._on_language_changed)

    def _on_language_changed(self, action: QAction) -> None:
        new_locale = action.data()
        if new_locale == self.config.locale:
            return
        self.config.locale = new_locale
        try:
            self.config.save(self.config_path)
        except OSError as e:
            print(f"warning: config save failed: {e}", file=sys.stderr)
        QMessageBox.information(
            self, tr("dialog.restart_title"), tr("dialog.restart_msg")
        )

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
        self._fast.stop()
        self._slow.stop()
        self._maint.stop()
        self.reader.stop()
        self.reader.wait(2000)
        self.store.close()
        super().closeEvent(event)
