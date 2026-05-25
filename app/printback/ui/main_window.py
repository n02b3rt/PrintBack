from __future__ import annotations

import time
from collections import deque
from pathlib import Path

import pyqtgraph as pg
from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QCloseEvent, QFont
from PySide6.QtWidgets import (
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMainWindow,
    QSplitter,
    QStatusBar,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..models import Observation
from ..serial_reader import SerialReader
from ..store import Store

ACTIVE_WINDOW_SEC = 300
LIVE_CHART_WINDOW_SEC = 60
HOURLY_WINDOW_SEC = 24 * 3600

_BG = "#14141c"
_PANEL = "#1e1e2a"
_FG = "#ddd"
_ACCENT = (120, 200, 255, 200)


def _format_age(ts: float) -> str:
    age = max(0, time.time() - ts)
    if age < 60:
        return f"{int(age)}s ago"
    if age < 3600:
        return f"{int(age // 60)}m ago"
    if age < 86400:
        return f"{int(age // 3600)}h ago"
    return f"{int(age // 86400)}d ago"


class KpiCard(QWidget):
    def __init__(self, label: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._label = QLabel(label)
        self._label.setStyleSheet("color: #888;")
        self._value = QLabel("--")
        f = QFont()
        f.setPointSize(28)
        f.setBold(True)
        self._value.setFont(f)
        v = QVBoxLayout(self)
        v.setContentsMargins(14, 10, 14, 12)
        v.addWidget(self._label)
        v.addWidget(self._value)
        self.setStyleSheet(
            f"KpiCard {{ background: {_PANEL}; border-radius: 8px; }}"
        )

    def set_value(self, text: str) -> None:
        self._value.setText(text)


class MainWindow(QMainWindow):
    def __init__(self, port: str, baud: int, db_path: Path) -> None:
        super().__init__()
        self.setWindowTitle("PrintBack")
        self.resize(1200, 760)

        self.store = Store(db_path)
        self._recent_fp: dict[str, float] = {}
        self._rate_buf: deque[float] = deque()
        self._live: deque[tuple[float, int]] = deque()

        self._build_ui()

        self.reader = SerialReader(port, baud, parent=self)
        self.reader.observation.connect(self._on_observation)
        self.reader.connection.connect(self._on_connection)
        self.reader.start()

        self._fast = QTimer(self)
        self._fast.setInterval(500)
        self._fast.timeout.connect(self._refresh_fast)
        self._fast.start()

        self._slow = QTimer(self)
        self._slow.setInterval(60_000)
        self._slow.timeout.connect(self._refresh_slow)
        self._slow.start()

        self._refresh_slow()

    def _build_ui(self) -> None:
        pg.setConfigOption("background", _PANEL)
        pg.setConfigOption("foreground", _FG)
        pg.setConfigOptions(antialias=True)

        root = QWidget(self)
        rl = QVBoxLayout(root)
        rl.setContentsMargins(12, 12, 12, 12)
        rl.setSpacing(10)

        kpi_row = QHBoxLayout()
        kpi_row.setSpacing(10)
        self.kpi_active = KpiCard("active devices (last 5 min)")
        self.kpi_total = KpiCard("observations (last 24h)")
        self.kpi_rate = KpiCard("events / min")
        kpi_row.addWidget(self.kpi_active)
        kpi_row.addWidget(self.kpi_total)
        kpi_row.addWidget(self.kpi_rate)
        rl.addLayout(kpi_row)

        splitter = QSplitter(Qt.Orientation.Horizontal, root)

        chart_col = QWidget()
        cv = QVBoxLayout(chart_col)
        cv.setContentsMargins(0, 0, 0, 0)
        cv.setSpacing(10)

        self.live_plot = pg.PlotWidget(title="live RSSI (last 60s)")
        self.live_plot.showGrid(x=True, y=True, alpha=0.2)
        self.live_plot.setLabel("left", "RSSI (dBm)")
        self.live_plot.setLabel("bottom", "time (s)")
        self.live_plot.setXRange(-LIVE_CHART_WINDOW_SEC, 0)
        self.live_plot.setYRange(-95, -25)
        self.live_scatter = pg.ScatterPlotItem(
            size=7, pen=None, brush=pg.mkBrush(*_ACCENT)
        )
        self.live_plot.addItem(self.live_scatter)
        cv.addWidget(self.live_plot, stretch=1)

        self.hourly_plot = pg.PlotWidget(title="hourly unique devices (last 24h)")
        self.hourly_plot.showGrid(x=True, y=True, alpha=0.2)
        self.hourly_plot.setLabel("left", "unique fp")
        self.hourly_plot.setAxisItems({"bottom": pg.DateAxisItem(orientation="bottom")})
        self.hourly_bars: pg.BarGraphItem | None = None
        cv.addWidget(self.hourly_plot, stretch=1)

        splitter.addWidget(chart_col)

        wl_col = QWidget()
        wlv = QVBoxLayout(wl_col)
        wlv.setContentsMargins(0, 0, 0, 0)
        wlv.setSpacing(6)
        wl_header = QLabel("whitelist (captured on device)")
        wl_header.setStyleSheet("color: #aaa; font-weight: bold; padding: 2px;")
        wlv.addWidget(wl_header)
        self.wl_table = QTableWidget(0, 3)
        self.wl_table.setHorizontalHeaderLabels(["fingerprint", "label", "added"])
        self.wl_table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )
        self.wl_table.verticalHeader().setVisible(False)
        self.wl_table.itemChanged.connect(self._on_label_changed)
        wlv.addWidget(self.wl_table, stretch=1)
        splitter.addWidget(wl_col)

        splitter.setStretchFactor(0, 3)
        splitter.setStretchFactor(1, 1)
        rl.addWidget(splitter, stretch=1)
        self.setCentralWidget(root)

        self.setStatusBar(QStatusBar(self))
        self.status_conn = QLabel("connecting…")
        self.statusBar().addWidget(self.status_conn)

        self.setStyleSheet(
            f"QMainWindow {{ background: {_BG}; }}"
            f"QLabel {{ color: {_FG}; }}"
            f"QTableWidget {{ background: {_PANEL}; color: {_FG};"
            f"  gridline-color: #2a2a3a; border: none; }}"
            f"QHeaderView::section {{ background: {_BG}; color: #aaa;"
            f"  border: none; padding: 4px; }}"
            f"QStatusBar {{ background: {_BG}; color: {_FG}; }}"
        )

    def _on_connection(self, ok: bool, msg: str) -> None:
        self.status_conn.setText(msg)
        self.status_conn.setStyleSheet(
            f"color: {'#7ee787' if ok else '#ff8080'};"
        )

    def _on_observation(self, obs: Observation) -> None:
        self.store.insert(obs)
        self.store.commit()
        self._recent_fp[obs.fp] = obs.received_at
        self._rate_buf.append(obs.received_at)
        self._live.append((obs.received_at, obs.rssi))
        if obs.whitelisted and self.store.remember_whitelisted(obs.fp):
            self._refresh_whitelist()

    def _refresh_fast(self) -> None:
        now = time.time()

        cutoff_active = now - ACTIVE_WINDOW_SEC
        self._recent_fp = {
            fp: t for fp, t in self._recent_fp.items() if t >= cutoff_active
        }
        self.kpi_active.set_value(str(len(self._recent_fp)))

        cutoff_rate = now - 60
        while self._rate_buf and self._rate_buf[0] < cutoff_rate:
            self._rate_buf.popleft()
        self.kpi_rate.set_value(str(len(self._rate_buf)))

        cutoff_live = now - LIVE_CHART_WINDOW_SEC
        while self._live and self._live[0][0] < cutoff_live:
            self._live.popleft()
        if self._live:
            xs = [t - now for t, _ in self._live]
            ys = [r for _, r in self._live]
            self.live_scatter.setData(xs, ys)
        else:
            self.live_scatter.setData([], [])

    def _refresh_slow(self) -> None:
        now = time.time()
        self.kpi_total.set_value(f"{self.store.total_since(now - 86400):,}")

        buckets = self.store.hourly_unique(now - HOURLY_WINDOW_SEC)
        if self.hourly_bars is not None:
            self.hourly_plot.removeItem(self.hourly_bars)
            self.hourly_bars = None
        if buckets:
            xs = [b + 1800 for b, _ in buckets]
            ys = [c for _, c in buckets]
            self.hourly_bars = pg.BarGraphItem(
                x=xs, height=ys, width=3000, brush=pg.mkBrush(*_ACCENT)
            )
            self.hourly_plot.addItem(self.hourly_bars)
        self._refresh_whitelist()

    def _refresh_whitelist(self) -> None:
        rows = self.store.whitelist()
        self.wl_table.blockSignals(True)
        self.wl_table.setRowCount(len(rows))
        for i, (fp, label, added_at) in enumerate(rows):
            short = fp[:12] + "…" if len(fp) > 12 else fp
            fp_item = QTableWidgetItem(short)
            fp_item.setFlags(fp_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            fp_item.setData(Qt.ItemDataRole.UserRole, fp)
            label_item = QTableWidgetItem(label or "")
            added_item = QTableWidgetItem(_format_age(added_at))
            added_item.setFlags(added_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            self.wl_table.setItem(i, 0, fp_item)
            self.wl_table.setItem(i, 1, label_item)
            self.wl_table.setItem(i, 2, added_item)
        self.wl_table.blockSignals(False)

    def _on_label_changed(self, item: QTableWidgetItem) -> None:
        if item.column() != 1:
            return
        fp_item = self.wl_table.item(item.row(), 0)
        if fp_item is None:
            return
        full_fp = fp_item.data(Qt.ItemDataRole.UserRole)
        self.store.set_label(full_fp, item.text().strip() or None)

    def closeEvent(self, event: QCloseEvent) -> None:
        self.reader.stop()
        self.reader.wait(2000)
        self.store.close()
        super().closeEvent(event)
