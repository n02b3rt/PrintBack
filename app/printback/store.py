from __future__ import annotations

import sqlite3
import time
from pathlib import Path

from .models import Observation

_SCHEMA = """
CREATE TABLE IF NOT EXISTS observations (
    received_at REAL NOT NULL,
    t_us        INTEGER NOT NULL,
    fp          TEXT NOT NULL,
    mac         TEXT NOT NULL,
    rssi        INTEGER NOT NULL,
    channel     INTEGER NOT NULL,
    ie_count    INTEGER NOT NULL,
    new         INTEGER NOT NULL,
    whitelisted INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_received_at ON observations(received_at);
CREATE INDEX IF NOT EXISTS idx_obs_fp_time     ON observations(fp, received_at);

CREATE TABLE IF NOT EXISTS whitelist (
    fp       TEXT PRIMARY KEY,
    label    TEXT,
    added_at REAL NOT NULL
);
"""


class Store:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.conn = sqlite3.connect(str(path))
        self.conn.execute("PRAGMA journal_mode = WAL")
        self.conn.execute("PRAGMA synchronous = NORMAL")
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.commit()
        self.conn.close()

    def insert(self, obs: Observation) -> None:
        self.conn.execute(
            "INSERT INTO observations VALUES (?,?,?,?,?,?,?,?,?)",
            (
                obs.received_at, obs.t_us, obs.fp, obs.mac, obs.rssi,
                obs.channel, obs.ie_count, int(obs.new), int(obs.whitelisted),
            ),
        )

    def commit(self) -> None:
        self.conn.commit()

    def remember_whitelisted(self, fp: str) -> bool:
        cur = self.conn.execute(
            "INSERT OR IGNORE INTO whitelist(fp, label, added_at) VALUES (?, NULL, ?)",
            (fp, time.time()),
        )
        return cur.rowcount > 0

    def set_label(self, fp: str, label: str | None) -> None:
        self.conn.execute("UPDATE whitelist SET label = ? WHERE fp = ?", (label, fp))
        self.conn.commit()

    def whitelist(self) -> list[tuple[str, str | None, float]]:
        return self.conn.execute(
            "SELECT fp, label, added_at FROM whitelist ORDER BY added_at DESC"
        ).fetchall()

    def unique_devices_since(self, since: float, exclude_wl: bool = True) -> int:
        sql = "SELECT COUNT(DISTINCT fp) FROM observations WHERE received_at >= ?"
        if exclude_wl:
            sql += " AND whitelisted = 0"
        row = self.conn.execute(sql, (since,)).fetchone()
        return int(row[0]) if row else 0

    def total_since(self, since: float) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) FROM observations WHERE received_at >= ?", (since,)
        ).fetchone()
        return int(row[0]) if row else 0

    def hourly_unique(self, since: float, exclude_wl: bool = True) -> list[tuple[int, int]]:
        wl = "AND whitelisted = 0" if exclude_wl else ""
        sql = f"""
            SELECT CAST(received_at / 3600 AS INTEGER) * 3600 AS bucket,
                   COUNT(DISTINCT fp)
            FROM observations
            WHERE received_at >= ? {wl}
            GROUP BY bucket
            ORDER BY bucket
        """
        return [(int(b), int(c)) for b, c in self.conn.execute(sql, (since,)).fetchall()]
