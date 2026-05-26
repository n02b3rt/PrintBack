from __future__ import annotations

import time
from collections import deque
from datetime import datetime

import pyqtgraph as pg
from PySide6.QtCore import Qt
from PySide6.QtGui import QBrush, QColor
from PySide6.QtWidgets import (
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QPlainTextEdit,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..config import Config
from ..models import LiveDevice, Observation
from ..store import Store
from . import theme


class _NumericItem(QTableWidgetItem):
    """QTableWidgetItem that sorts by stored numeric value rather than text."""

    def __init__(self, value: float, text: str | None = None) -> None:
        super().__init__(text if text is not None else str(value))
        self._value = float(value)

    def __lt__(self, other: "QTableWidgetItem") -> bool:
        if isinstance(other, _NumericItem):
            return self._value < other._value
        return super().__lt__(other)


_SOURCE_COLOR = {
    "device": theme.WL_DEVICE,
    "manual": theme.WL_MANUAL,
    "auto": theme.WL_AUTO,
}


class DebugTab(QWidget):
    def __init__(self, store: Store, config: Config, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.store = store
        self.config = config

        self._rate_buf: deque[float] = deque()
        self._live_rssi: deque[tuple[float, int]] = deque()
        self._channel_buf: dict[int, int] = {}
        self._raw_log_lines: deque[str] = deque(maxlen=200)

        self._build_ui()

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(10)

        # Top row: small KPIs + RSSI scatter
        top_row = QHBoxLayout()
        top_row.setSpacing(10)

        kpi_col = QVBoxLayout()
        kpi_col.setSpacing(6)
        self.lbl_rate = self._make_stat("events / min", "--")
        self.lbl_obs_24h = self._make_stat("obs / 24h", "--")
        self.lbl_ch1 = self._make_stat("ch 1", "--")
        self.lbl_ch6 = self._make_stat("ch 6", "--")
        self.lbl_ch11 = self._make_stat("ch 11", "--")
        self.lbl_candidates = self._make_stat("auto-WL kandydaci", "--")
        for w in (self.lbl_rate, self.lbl_obs_24h, self.lbl_ch1,
                  self.lbl_ch6, self.lbl_ch11, self.lbl_candidates):
            kpi_col.addWidget(w)
        kpi_col.addStretch()
        kpi_wrap = QWidget()
        kpi_wrap.setLayout(kpi_col)
        kpi_wrap.setFixedWidth(180)
        top_row.addWidget(kpi_wrap)

        self.rssi_plot = pg.PlotWidget(title="live RSSI (ostatnie 60s)")
        self.rssi_plot.showGrid(x=True, y=True, alpha=0.2)
        self.rssi_plot.setLabel("left", "RSSI (dBm)")
        self.rssi_plot.setLabel("bottom", "czas (s)")
        self.rssi_plot.setXRange(-self.config.live_chart_window_seconds, 0)
        self.rssi_plot.setYRange(-95, -25)
        self.rssi_scatter = pg.ScatterPlotItem(
            size=7, pen=None, brush=pg.mkBrush(*theme.ACCENT)
        )
        self.rssi_plot.addItem(self.rssi_scatter)
        top_row.addWidget(self.rssi_plot, stretch=1)

        root.addLayout(top_row, stretch=1)

        # Middle: live devices table (sortable, default RSSI desc)
        self._build_devices_table()
        root.addWidget(self._devices_wrap, stretch=2)

        # Bottom: raw event log
        log_label = QLabel("raw event log (ostatnie 200)")
        log_label.setStyleSheet(f"color: {theme.MUTED};")
        root.addWidget(log_label)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(200)
        self.log.setFixedHeight(140)
        root.addWidget(self.log)

    def _make_stat(self, label: str, value: str) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(10, 6, 10, 6)
        v.setSpacing(0)
        lbl = QLabel(label)
        lbl.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
        val = QLabel(value)
        val.setStyleSheet(f"color: {theme.FG}; font-size: 18px; font-weight: bold;")
        v.addWidget(lbl)
        v.addWidget(val)
        w.setStyleSheet(f"QWidget {{ background: {theme.PANEL}; border-radius: 6px; }}")
        w._val = val  # type: ignore[attr-defined]
        return w

    def _set_stat(self, w: QWidget, value: str, color: str | None = None) -> None:
        lbl: QLabel = w._val  # type: ignore[attr-defined]
        lbl.setText(value)
        if color:
            lbl.setStyleSheet(f"color: {color}; font-size: 18px; font-weight: bold;")

    def _build_devices_table(self) -> None:
        self._devices_wrap = QWidget()
        v = QVBoxLayout(self._devices_wrap)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)

        header = QLabel("aktywne urządzenia (ostatnie 5 min) — sortuj klikając w nagłówek")
        header.setStyleSheet(f"color: {theme.MUTED};")
        v.addWidget(header)

        cols = ["fp", "mac", "RSSI", "śr. RSSI", "# obs", "pierwszy", "ostatni", "ch", "status"]
        self.dev_table = QTableWidget(0, len(cols))
        self.dev_table.setHorizontalHeaderLabels(cols)
        self.dev_table.setSortingEnabled(True)
        self.dev_table.verticalHeader().setVisible(False)
        self.dev_table.setSelectionBehavior(
            QTableWidget.SelectionBehavior.SelectRows
        )
        self.dev_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        h = self.dev_table.horizontalHeader()
        h.setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        h.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        # default sort by RSSI desc (col index 2)
        self.dev_table.sortItems(2, Qt.SortOrder.DescendingOrder)
        v.addWidget(self.dev_table)

    # ---------- live observation tracking ----------

    def on_observation(self, obs: Observation) -> None:
        self._rate_buf.append(obs.received_at)
        self._live_rssi.append((obs.received_at, obs.rssi))
        self._channel_buf[obs.channel] = self._channel_buf.get(obs.channel, 0) + 1
        flags = []
        if obs.new:
            flags.append("new")
        if obs.whitelisted:
            flags.append("wl")
        flag_str = f" [{','.join(flags)}]" if flags else ""
        ts = datetime.fromtimestamp(obs.received_at).strftime("%H:%M:%S.%f")[:-3]
        line = (
            f"{ts}  fp={obs.fp[:12]}…  mac={obs.mac}  rssi={obs.rssi:+4d}  "
            f"ch={obs.channel}{flag_str}"
        )
        self._raw_log_lines.append(line)

    def tick(self) -> None:
        now = time.time()

        # rate / min
        rate_cutoff = now - 60
        while self._rate_buf and self._rate_buf[0] < rate_cutoff:
            self._rate_buf.popleft()
        self._set_stat(self.lbl_rate, str(len(self._rate_buf)))

        # rolling rssi chart
        live_cutoff = now - self.config.live_chart_window_seconds
        while self._live_rssi and self._live_rssi[0][0] < live_cutoff:
            self._live_rssi.popleft()
        if self._live_rssi:
            xs = [t - now for t, _ in self._live_rssi]
            ys = [r for _, r in self._live_rssi]
            self.rssi_scatter.setData(xs, ys)
        else:
            self.rssi_scatter.setData([], [])

        # raw log: only append last few new lines
        if self._raw_log_lines:
            text = "\n".join(self._raw_log_lines)
            # cheap: replace whole content
            self.log.setPlainText(text)
            self.log.verticalScrollBar().setValue(
                self.log.verticalScrollBar().maximum()
            )

    # ---------- slow refresh ----------

    def refresh_slow(self) -> None:
        # observations in last 24h
        obs_24h = self.store.total_observations_since(time.time() - 86400)
        self._set_stat(self.lbl_obs_24h, f"{obs_24h:,}")

        # channels (over last 5 min from rolling buffer)
        total_ch = sum(self._channel_buf.values()) or 1
        for ch, lbl in ((1, self.lbl_ch1), (6, self.lbl_ch6), (11, self.lbl_ch11)):
            n = self._channel_buf.get(ch, 0)
            pct = 100 * n / total_ch
            self._set_stat(lbl, f"{pct:.0f}%")

        # auto-WL candidates count
        candidates = self.store.auto_wl_candidates(
            window_hours=self.config.auto_wl_window_hours,
            min_distinct_hours=self.config.auto_wl_min_distinct_hours,
            min_observations=self.config.auto_wl_min_observations,
        )
        already_wl = self.store.whitelist_fps()
        pending = [c for c in candidates if c[0] not in already_wl]
        color = theme.WARN if pending else theme.MUTED
        self._set_stat(self.lbl_candidates, str(len(pending)), color=color)

        # devices table
        devices = self.store.live_devices(self.config.live_table_window_seconds)
        self._populate_devices_table(devices)

    def _populate_devices_table(self, devices: list[LiveDevice]) -> None:
        self.dev_table.setSortingEnabled(False)
        self.dev_table.setRowCount(len(devices))
        now = time.time()
        for row, d in enumerate(devices):
            status = self._status_for(d)
            short_fp = d.fp[:12] + "…" if len(d.fp) > 12 else d.fp
            cells = [
                QTableWidgetItem(short_fp),
                QTableWidgetItem(d.mac),
                _NumericItem(d.last_rssi, f"{d.last_rssi:+d}"),
                _NumericItem(d.avg_rssi, f"{d.avg_rssi:+.1f}"),
                _NumericItem(d.n_obs, str(d.n_obs)),
                _NumericItem(d.first_seen, f"{int(now - d.first_seen)}s temu"),
                _NumericItem(d.last_seen, f"{int(now - d.last_seen)}s temu"),
                QTableWidgetItem(",".join(str(c) for c in sorted(d.channels))),
                QTableWidgetItem(status),
            ]
            cells[0].setData(Qt.ItemDataRole.UserRole, d.fp)
            cells[0].setToolTip(d.fp)
            # color status cell + dim row if whitelisted
            status_color = self._status_color(d)
            if status_color:
                cells[-1].setForeground(QBrush(QColor(status_color)))
            if d.wl_source is not None:
                for c in cells:
                    c.setForeground(QBrush(QColor("#6a6a7a")))
            for col, item in enumerate(cells):
                self.dev_table.setItem(row, col, item)
        self.dev_table.setSortingEnabled(True)

    def _status_for(self, d: LiveDevice) -> str:
        if d.wl_source:
            return f"wl:{d.wl_source}"
        return "klient"

    def _status_color(self, d: LiveDevice) -> str | None:
        if d.wl_source:
            return _SOURCE_COLOR.get(d.wl_source, theme.MUTED)
        return None
