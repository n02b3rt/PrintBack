from __future__ import annotations

import time
from datetime import date, datetime, timedelta

import pyqtgraph as pg
from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QVBoxLayout,
    QWidget,
)

from ..config import Config
from ..models import Observation
from ..store import Store
from . import theme


class KpiCard(QWidget):
    def __init__(self, label: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._label = QLabel(label)
        self._label.setStyleSheet(f"color: {theme.MUTED};")
        self._value = QLabel("--")
        vf = QFont()
        vf.setPointSize(26)
        vf.setBold(True)
        self._value.setFont(vf)
        self._sub = QLabel("")
        self._sub.setStyleSheet(f"color: {theme.MUTED};")
        v = QVBoxLayout(self)
        v.setContentsMargins(14, 10, 14, 12)
        v.setSpacing(2)
        v.addWidget(self._label)
        v.addWidget(self._value)
        v.addWidget(self._sub)
        self.setStyleSheet(
            f"KpiCard {{ background: {theme.PANEL}; border-radius: 8px; }}"
        )

    def set_value(self, text: str, sub: str = "", sub_color: str | None = None) -> None:
        self._value.setText(text)
        self._sub.setText(sub)
        self._sub.setStyleSheet(f"color: {sub_color or theme.MUTED};")


class StatsTab(QWidget):
    def __init__(self, store: Store, config: Config, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.store = store
        self.config = config
        self._recent_fp: dict[str, float] = {}
        self._build_ui()

    def _build_ui(self) -> None:
        pg.setConfigOption("background", theme.PANEL)
        pg.setConfigOption("foreground", theme.FG)
        pg.setConfigOptions(antialias=True)

        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(10)

        # KPI grid: 4 cards
        kpi_row = QHBoxLayout()
        kpi_row.setSpacing(10)
        self.kpi_active = KpiCard("aktywni teraz (5 min)")
        self.kpi_today = KpiCard("dziś unikalnych")
        self.kpi_new = KpiCard("nowi dziś")
        self.kpi_returning = KpiCard("powracający dziś")
        for c in (self.kpi_active, self.kpi_today, self.kpi_new, self.kpi_returning):
            kpi_row.addWidget(c)
        root.addLayout(kpi_row)

        # Charts row: frequency segments + trend
        charts_row = QHBoxLayout()
        charts_row.setSpacing(10)

        self.freq_plot = pg.PlotWidget(title="powracający vs nowi — segmenty (ostatnie 30 dni)")
        self.freq_plot.showGrid(x=False, y=True, alpha=0.2)
        self.freq_plot.setLabel("left", "liczba urządzeń")
        self.freq_bars: pg.BarGraphItem | None = None
        charts_row.addWidget(self.freq_plot, stretch=1)

        self.trend_plot = pg.PlotWidget(title="ruch dzienny (ostatnie 30 dni)")
        self.trend_plot.showGrid(x=True, y=True, alpha=0.2)
        self.trend_plot.setLabel("left", "unikalnych / dzień")
        self.trend_plot.setAxisItems({"bottom": pg.DateAxisItem(orientation="bottom")})
        self.trend_curve = self.trend_plot.plot(
            [], [], pen=pg.mkPen(theme.ACCENT_HEX, width=2), symbol="o", symbolSize=6,
            symbolBrush=pg.mkBrush(*theme.ACCENT), symbolPen=None,
        )
        self.trend_ma = self.trend_plot.plot(
            [], [], pen=pg.mkPen("#aaaaaa", width=1, style=Qt.PenStyle.DashLine),
        )
        charts_row.addWidget(self.trend_plot, stretch=2)

        root.addLayout(charts_row, stretch=1)

    # ---------- live observation tracking ----------

    def on_observation(self, obs: Observation) -> None:
        if obs.whitelisted:
            return
        self._recent_fp[obs.fp] = obs.received_at

    def tick(self) -> None:
        now = time.time()
        cutoff = now - self.config.active_window_seconds
        self._recent_fp = {fp: t for fp, t in self._recent_fp.items() if t >= cutoff}
        self.kpi_active.set_value(str(len(self._recent_fp)))

    # ---------- slow refresh (DB queries) ----------

    def refresh_slow(self) -> None:
        stats = self.store.live_today_stats(self.config.returning_window_days)
        self.kpi_today.set_value(str(stats["total"]))
        self.kpi_new.set_value(str(stats["new"]))
        self.kpi_returning.set_value(str(stats["returning"]))

        # vs yesterday delta on "today total"
        y = self.store.yesterday_total()
        if y > 0:
            delta = stats["total"] - y
            pct = (delta / y) * 100
            arrow = "▲" if delta > 0 else ("▼" if delta < 0 else "•")
            color = theme.OK if delta > 0 else (theme.BAD if delta < 0 else theme.MUTED)
            self.kpi_today.set_value(
                str(stats["total"]),
                sub=f"{arrow} {delta:+d} ({pct:+.0f}%) vs wczoraj ({y})",
                sub_color=color,
            )
        else:
            self.kpi_today.set_value(str(stats["total"]), sub="brak danych wczoraj")

        # frequency segments bar chart
        segments = self.store.frequency_segments(30)
        xs = list(range(len(segments)))
        ys = [c for _, c in segments]
        labels = [name for name, _ in segments]
        if self.freq_bars is not None:
            self.freq_plot.removeItem(self.freq_bars)
        self.freq_bars = pg.BarGraphItem(
            x=xs, height=ys, width=0.6, brush=pg.mkBrush(*theme.ACCENT)
        )
        self.freq_plot.addItem(self.freq_bars)
        ax = self.freq_plot.getAxis("bottom")
        ax.setTicks([list(zip(xs, labels))])

        # 30-day trend
        today = date.today()
        start = today - timedelta(days=30)
        rows = self.store.daily_totals_range(start.isoformat(), today.isoformat())
        if rows:
            xs_t = [datetime.fromisoformat(d).timestamp() + 43200 for d, *_ in rows]
            ys_t = [t for _, t, _, _ in rows]
            self.trend_curve.setData(xs_t, ys_t)
            # 7-day moving average
            if len(ys_t) >= 3:
                ma = []
                for i in range(len(ys_t)):
                    window = ys_t[max(0, i - 6):i + 1]
                    ma.append(sum(window) / len(window))
                self.trend_ma.setData(xs_t, ma)
            else:
                self.trend_ma.setData([], [])
        else:
            self.trend_curve.setData([], [])
            self.trend_ma.setData([], [])
