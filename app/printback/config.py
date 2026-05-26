from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, fields
from pathlib import Path


def default_app_dir() -> Path:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA")
        if base:
            return Path(base) / "PrintBack"
    elif sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "PrintBack"
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / "PrintBack"
    return Path.home() / ".local" / "share" / "PrintBack"


@dataclass(slots=True)
class Config:
    # retention windows
    l1_retention_days: int = 30
    l2_retention_days: int = 365

    # stats windows
    returning_window_days: int = 30
    active_window_seconds: int = 300
    live_chart_window_seconds: int = 60
    live_table_window_seconds: int = 300

    # auto-whitelist heuristic
    auto_wl_window_hours: int = 8
    auto_wl_min_distinct_hours: int = 6
    auto_wl_min_observations: int = 30

    # maintenance cadence
    maintenance_interval_minutes: int = 60
    backup_keep_days: int = 7

    # serial
    serial_baud: int = 115200

    # i18n
    locale: str = "pl"  # "pl" or "en"

    @classmethod
    def load(cls, path: Path) -> "Config":
        if not path.exists():
            cfg = cls()
            cfg.save(path)
            return cfg
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return cls()
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")
