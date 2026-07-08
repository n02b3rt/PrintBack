from __future__ import annotations

import time
from datetime import datetime

import pyqtgraph as pg
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QVBoxLayout,
    QWidget,
)

from ..config import Config
from ..i18n import tr
from ..models import Observation
from ..store import Store
from . import theme


class HeroCard(QWidget):
    """Headline KPI: single large number, secondary line below."""

    def __init__(self, title: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._title = QLabel(title)
        self._title.setStyleSheet(f"color: {theme.MUTED}; font-size: 13px;")

        self._value = QLabel("--")
        vf = QFont()
        vf.setPointSize(44)
        vf.setBold(True)
        self._value.setFont(vf)

        self._sub = QLabel("")
        sf = QFont()
        sf.setPointSize(13)
        self._sub.setFont(sf)
        self._sub.setStyleSheet(f"color: {theme.MUTED};")

        v = QVBoxLayout(self)
        v.setContentsMargins(24, 16, 24, 18)
        v.setSpacing(2)
        v.addWidget(self._title)
        v.addWidget(self._value)
        v.addWidget(self._sub)
        self.setStyleSheet(
            f"HeroCard {{ background: {theme.PANEL}; border-radius: 10px; }}"
        )

    def set_value(self, text: str, sub: str = "", sub_color: str | None = None) -> None:
        self._value.setText(text)
        self._sub.setText(sub)
        self._sub.setStyleSheet(
            f"color: {sub_color or theme.MUTED}; font-size: 13px;"
        )


class KpiCard(QWidget):
    """Secondary KPI: medium number + optional sub-line."""

    def __init__(self, label: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._label = QLabel(label)
        self._label.setStyleSheet(f"color: {theme.MUTED};")
        self._value = QLabel("--")
        vf = QFont()
        vf.setPointSize(24)
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

        # Hero
        self.hero = HeroCard(tr("hero.title"))
        root.addWidget(self.hero)

        # Secondary KPI row
        kpi_row = QHBoxLayout()
        kpi_row.setSpacing(10)
        self.kpi_active = KpiCard(tr("kpi.active_now"))
        self.kpi_returning = KpiCard(tr("kpi.returning_today"))
        self.kpi_new = KpiCard(tr("kpi.new_today"))
        for c in (self.kpi_active, self.kpi_returning, self.kpi_new):
            kpi_row.addWidget(c)
        root.addLayout(kpi_row)

        # Today by hour, full width, fixed X
        self.hourly_plot = self._make_bar_plot(
            title=tr("chart.today_hourly"),
            y_label=tr("chart.today_hourly_y"),
            x_label=tr("chart.today_hourly_x"),
        )
        self.hourly_plot.setXRange(-0.5, 23.5, padding=0)
        self.hourly_plot.setLimits(xMin=-0.6, xMax=23.6, yMin=0)
        self.hourly_plot.getAxis("bottom").setTicks(
            [[(h, f"{h:02d}") for h in range(0, 24, 2)]]
        )
        self.hourly_bars: pg.BarGraphItem | None = None
        root.addWidget(self.hourly_plot, stretch=2)

        # Bottom row: last 7 days + frequency segments
        bottom = QHBoxLayout()
        bottom.setSpacing(10)

        self.week_plot = self._make_bar_plot(
            title=tr("chart.last_7_days"),
            y_label=tr("chart.last_7_days_y"),
        )
        self.week_plot.setXRange(-0.5, 6.5, padding=0)
        self.week_plot.setLimits(xMin=-0.6, xMax=6.6, yMin=0)
        self.week_bars: pg.BarGraphItem | None = None
        bottom.addWidget(self.week_plot, stretch=1)

        self.freq_plot = self._make_bar_plot(
            title=tr("chart.freq_segments"),
            y_label=tr("chart.freq_y"),
        )
        self.freq_plot.setXRange(-0.5, 3.5, padding=0)
        self.freq_plot.setLimits(xMin=-0.6, xMax=3.6, yMin=0)
        self.freq_bars: pg.BarGraphItem | None = None
        bottom.addWidget(self.freq_plot, stretch=1)

        root.addLayout(bottom, stretch=2)

    def _make_bar_plot(
        self, title: str, y_label: str, x_label: str | None = None,
    ) -> pg.PlotWidget:
        p = pg.PlotWidget(title=title)
        p.showGrid(x=False, y=True, alpha=0.2)
        p.setLabel("left", y_label)
        if x_label:
            p.setLabel("bottom", x_label)
        p.setMouseEnabled(x=False, y=False)
        p.setMenuEnabled(False)
        p.hideButtons()
        return p

    # ---------- observation tracking ----------

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
        total = int(stats["total"])
        n_new = int(stats["new"])
        n_ret = int(stats["returning"])

        # Hero
        y = self.store.yesterday_total()
        if y > 0:
            delta = total - y
            pct = (delta / y) * 100
            arrow = "▲" if delta > 0 else ("▼" if delta < 0 else "•")
            color = theme.OK if delta > 0 else (theme.BAD if delta < 0 else theme.MUTED)
            self.hero.set_value(
                str(total),
                sub=tr("kpi.today.delta_yesterday",
                       arrow=arrow, delta=delta, pct=pct, y=y),
                sub_color=color,
            )
        else:
            self.hero.set_value(str(total), sub=tr("kpi.today.no_yesterday"))

        # Secondary
        ret_pct = (n_ret / total * 100) if total > 0 else 0
        new_pct = (n_new / total * 100) if total > 0 else 0
        self.kpi_returning.set_value(str(n_ret), sub=f"({ret_pct:.0f}%)")
        self.kpi_new.set_value(str(n_new), sub=f"({new_pct:.0f}%)")

        # Today by hour
        hours = self.store.today_hourly()
        self._draw_bars(
            self.hourly_plot, "hourly_bars",
            xs=list(range(24)), ys=hours, width=0.75,
        )

        # Last 7 days
        week = self.store.last_n_days_totals(7)
        xs_w = list(range(len(week)))
        ys_w = [c for _, _, c in week]
        labels_w = []
        for date_str, weekday, _ in week:
            d = datetime.fromisoformat(date_str)
            labels_w.append(f"{tr(f'day.{weekday}')}\n{d.day:02d}.{d.month:02d}")
        self.week_plot.getAxis("bottom").setTicks([list(zip(xs_w, labels_w))])
        self._draw_bars(
            self.week_plot, "week_bars",
            xs=xs_w, ys=ys_w, width=0.65,
        )

        # Frequency segments
        segments = self.store.frequency_segments(30)
        xs_f = list(range(len(segments)))
        ys_f = [c for _, c in segments]
        labels_f = [tr(f"freq.{key}") for key, _ in segments]
        self.freq_plot.getAxis("bottom").setTicks([list(zip(xs_f, labels_f))])
        self._draw_bars(
            self.freq_plot, "freq_bars",
            xs=xs_f, ys=ys_f, width=0.65,
        )

    def _draw_bars(
        self, plot: pg.PlotWidget, attr: str,
        xs: list[int], ys: list[int], width: float,
    ) -> None:
        old = getattr(self, attr)
        if old is not None:
            plot.removeItem(old)
        max_y = max(ys) if ys else 0
        plot.setYRange(0, max(1, max_y * 1.15))
        bars = pg.BarGraphItem(
            x=xs, height=ys, width=width, brush=pg.mkBrush(*theme.ACCENT),
        )
        plot.addItem(bars)
        setattr(self, attr, bars)
