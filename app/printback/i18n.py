"""Tiny dict-based i18n. Two locales (pl, en). Default pl.

Usage:
    from .i18n import tr, set_locale
    set_locale("en")            # once at app start, from config
    tr("kpi.active_now")        # → "active now (last 5 min)"
    tr("kpi.today.delta", arrow="▲", delta=5, pct=10.0, y=42)  # supports .format kwargs
"""

from __future__ import annotations

TRANSLATIONS: dict[str, dict[str, str]] = {
    "pl": {
        # tabs
        "tab.stats": "Statystyki",
        "tab.debug": "Debug",

        # KPI cards — stats tab
        "kpi.active_now": "aktywni teraz (5 min)",
        "kpi.today_unique": "dziś unikalnych",
        "kpi.new_today": "nowi dziś",
        "kpi.returning_today": "powracający dziś",
        "kpi.today.delta_yesterday":
            "{arrow} {delta:+d} ({pct:+.0f}%) vs wczoraj ({y})",
        "kpi.today.no_yesterday": "brak danych wczoraj",

        # KPI cards — debug tab
        "kpi.events_per_min": "events / min",
        "kpi.obs_24h": "obs / 24h",
        "kpi.ch": "ch {ch}",
        "kpi.auto_wl_candidates": "auto-WL kandydaci",

        # charts
        "chart.today_hourly": "ruch godzinowo — dzisiaj",
        "chart.today_hourly_x": "godzina",
        "chart.today_hourly_y": "unikalnych",
        "chart.last_7_days": "ostatnie 7 dni",
        "chart.last_7_days_y": "unikalnych",
        "chart.freq_segments": "segmenty częstotliwości (ostatnie 30 dni)",
        "chart.freq_y": "liczba urządzeń",
        "chart.live_rssi": "live RSSI (ostatnie 60s)",
        "chart.live_rssi_x": "czas (s)",
        "chart.live_rssi_y": "RSSI (dBm)",

        # hero card + weekday short names
        "hero.title": "Dziś klientów",
        "day.0": "Pn", "day.1": "Wt", "day.2": "Śr",
        "day.3": "Cz", "day.4": "Pt", "day.5": "Sb", "day.6": "Nd",

        # frequency segments
        "freq.1_visit": "1 wizyta",
        "freq.2_3": "2-3",
        "freq.4_7": "4-7",
        "freq.8_plus": "8+",

        # devices table (debug tab)
        "devices.header": "aktywne urządzenia (ostatnie 5 min) — sortuj klikając w nagłówek",
        "devices.col.fp": "fingerprint",
        "devices.col.mac": "mac",
        "devices.col.rssi": "RSSI",
        "devices.col.avg_rssi": "śr. RSSI",
        "devices.col.n_obs": "# obs",
        "devices.col.first": "pierwszy",
        "devices.col.last": "ostatni",
        "devices.col.channel": "ch",
        "devices.col.status": "status",
        "devices.status.client": "klient",
        "devices.ago_s": "{s}s temu",

        # raw log
        "rawlog.label": "raw event log (ostatnie 200)",

        # whitelist panel
        "wl.header": "whitelist",
        "wl.col.fp": "fingerprint",
        "wl.col.label": "label",
        "wl.col.source": "src",
        "wl.col.age": "added",
        "wl.menu.remove": "usuń z whitelisty",
        "wl.menu.false_positive": "oznacz jako false-positive (nie auto-WL ponownie)",
        "wl.tooltip.added": "dodano: {when}",
        "wl.tooltip.reason": "powód: {reason}",

        # status bar
        "status.connecting": "łączenie…",
        "status.db": "db: {path}",
        "status.stale": "{base} — brak danych od {age}s, sprawdź urządzenie",

        # menu
        "menu.settings": "Ustawienia",
        "menu.language": "Język",
        "menu.language.pl": "Polski",
        "menu.language.en": "English",

        # dialogs
        "dialog.restart_title": "Restart wymagany",
        "dialog.restart_msg":
            "Zmiana języka wejdzie po restarcie aplikacji.",
    },
    "en": {
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

        "devices.header": "active devices (last 5 min) — click header to sort",
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
        "status.stale": "{base} — no data for {age}s, check device",

        "menu.settings": "Settings",
        "menu.language": "Language",
        "menu.language.pl": "Polski",
        "menu.language.en": "English",

        "dialog.restart_title": "Restart required",
        "dialog.restart_msg":
            "Language change will take effect after restarting the app.",
    },
}

_DEFAULT_LOCALE = "pl"
_current_locale = _DEFAULT_LOCALE


def set_locale(locale: str) -> None:
    global _current_locale
    if locale in TRANSLATIONS:
        _current_locale = locale


def current_locale() -> str:
    return _current_locale


def tr(key: str, **kwargs: object) -> str:
    table = TRANSLATIONS.get(_current_locale) or TRANSLATIONS[_DEFAULT_LOCALE]
    template = table.get(key) or TRANSLATIONS[_DEFAULT_LOCALE].get(key) or key
    if kwargs:
        try:
            return template.format(**kwargs)
        except (KeyError, IndexError, ValueError):
            return template
    return template
