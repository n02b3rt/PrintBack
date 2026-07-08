"""Tiny dict-based string lookup for UI labels.

Usage:
    from .i18n import tr
    tr("kpi.active_now")        # -> "active now (last 5 min)"
    tr("kpi.today.delta", arrow="▲", delta=5, pct=10.0, y=42)  # supports .format kwargs
"""

from __future__ import annotations

STRINGS: dict[str, str] = {
    "tab.stats": "Statistics",
    "tab.debug": "Debug",

    "kpi.active_now": "active now (last 5 min)",
    "kpi.today_unique": "unique today",
    "kpi.new_today": "new today",
    "kpi.returning_today": "returning today",
    "kpi.today.delta_yesterday":
        "{arrow} {delta:+d} ({pct:+.0f}%) vs yesterday ({y})",
    "kpi.today.no_yesterday": "no yesterday data",

    "kpi.events_per_min": "events / min",
    "kpi.obs_24h": "obs / 24h",
    "kpi.ch": "ch {ch}",
    "kpi.auto_wl_candidates": "auto-WL candidates",

    "chart.today_hourly": "today by hour",
    "chart.today_hourly_x": "hour",
    "chart.today_hourly_y": "unique",
    "chart.last_7_days": "last 7 days",
    "chart.last_7_days_y": "unique",
    "chart.freq_segments": "visit frequency segments (last 30 days)",
    "chart.freq_y": "device count",
    "chart.live_rssi": "live RSSI (last 60s)",
    "chart.live_rssi_x": "time (s)",
    "chart.live_rssi_y": "RSSI (dBm)",

    "hero.title": "Customers today",
    "day.0": "Mon", "day.1": "Tue", "day.2": "Wed",
    "day.3": "Thu", "day.4": "Fri", "day.5": "Sat", "day.6": "Sun",

    "freq.1_visit": "1 visit",
    "freq.2_3": "2-3",
    "freq.4_7": "4-7",
    "freq.8_plus": "8+",

    "devices.header": "active devices (last 5 min), click header to sort",
    "devices.col.fp": "fingerprint",
    "devices.col.mac": "mac",
    "devices.col.rssi": "RSSI",
    "devices.col.avg_rssi": "avg RSSI",
    "devices.col.n_obs": "# obs",
    "devices.col.first": "first",
    "devices.col.last": "last",
    "devices.col.channel": "ch",
    "devices.col.status": "status",
    "devices.status.client": "customer",
    "devices.ago_s": "{s}s ago",

    "rawlog.label": "raw event log (last 200)",

    "wl.header": "whitelist",
    "wl.col.fp": "fingerprint",
    "wl.col.label": "label",
    "wl.col.source": "src",
    "wl.col.age": "added",
    "wl.menu.remove": "remove from whitelist",
    "wl.menu.false_positive": "mark as false positive (don't auto-WL again)",
    "wl.tooltip.added": "added: {when}",
    "wl.tooltip.reason": "reason: {reason}",

    "status.connecting": "connecting…",
    "status.db": "db: {path}",
    "status.stale": "{base}, no data for {age}s, check device",
}


def tr(key: str, **kwargs: object) -> str:
    template = STRINGS.get(key, key)
    if kwargs:
        try:
            return template.format(**kwargs)
        except (KeyError, IndexError, ValueError):
            return template
    return template
