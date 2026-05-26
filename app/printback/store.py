from __future__ import annotations

import json
import sqlite3
import time
from datetime import date, datetime, timedelta
from pathlib import Path

from .models import LiveDevice, Observation

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

CREATE TABLE IF NOT EXISTS daily_visits (
    fp              TEXT NOT NULL,
    visit_date      TEXT NOT NULL,
    first_seen_at   REAL NOT NULL,
    last_seen_at    REAL NOT NULL,
    n_observations  INTEGER NOT NULL,
    distinct_hours  INTEGER NOT NULL,
    was_new         INTEGER NOT NULL,
    PRIMARY KEY (fp, visit_date)
);
CREATE INDEX IF NOT EXISTS idx_dv_date ON daily_visits(visit_date);
CREATE INDEX IF NOT EXISTS idx_dv_fp   ON daily_visits(fp);

CREATE TABLE IF NOT EXISTS daily_totals (
    date             TEXT PRIMARY KEY,
    total_unique     INTEGER NOT NULL,
    n_new            INTEGER NOT NULL,
    n_returning      INTEGER NOT NULL,
    hourly_counts    TEXT NOT NULL,
    channel_counts   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS whitelist (
    fp             TEXT PRIMARY KEY,
    label          TEXT,
    added_at       REAL NOT NULL,
    wl_source      TEXT NOT NULL DEFAULT 'device',
    auto_wl_reason TEXT
);

CREATE TABLE IF NOT EXISTS auto_wl_blacklist (
    fp        TEXT PRIMARY KEY,
    added_at  REAL NOT NULL,
    note      TEXT
);

CREATE TABLE IF NOT EXISTS retention_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    last_maintenance_run    REAL,
    last_backup_date        TEXT,
    aggregated_through_date TEXT
);
INSERT OR IGNORE INTO retention_meta(id) VALUES (1);
"""


def _today() -> date:
    return datetime.now().date()


def _date_str(d: date) -> str:
    return d.isoformat()


def _day_bounds(d: date) -> tuple[float, float]:
    start = datetime.combine(d, datetime.min.time()).timestamp()
    end = datetime.combine(d + timedelta(days=1), datetime.min.time()).timestamp()
    return start, end


class Store:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(path))
        self.conn.execute("PRAGMA journal_mode = WAL")
        self.conn.execute("PRAGMA synchronous = NORMAL")
        self.conn.execute("PRAGMA foreign_keys = ON")
        self._migrate()

    def _migrate(self) -> None:
        # Add missing columns to pre-existing whitelist (v0 → v1).
        cols = {row[1] for row in self.conn.execute("PRAGMA table_info(whitelist)")}
        if cols and "wl_source" not in cols:
            self.conn.execute(
                "ALTER TABLE whitelist ADD COLUMN wl_source TEXT NOT NULL DEFAULT 'device'"
            )
        if cols and "auto_wl_reason" not in cols:
            self.conn.execute("ALTER TABLE whitelist ADD COLUMN auto_wl_reason TEXT")
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.commit()
        self.conn.close()

    # ---------- raw observations (L1) ----------

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

    def earliest_observation_date(self) -> date | None:
        row = self.conn.execute(
            "SELECT MIN(received_at) FROM observations"
        ).fetchone()
        if not row or row[0] is None:
            return None
        return datetime.fromtimestamp(row[0]).date()

    def delete_observations_before(self, cutoff: float) -> int:
        cur = self.conn.execute(
            "DELETE FROM observations WHERE received_at < ?", (cutoff,)
        )
        self.commit()
        return cur.rowcount

    # ---------- whitelist + blacklist ----------

    def whitelist_fps(self) -> set[str]:
        return {row[0] for row in self.conn.execute("SELECT fp FROM whitelist")}

    def blacklist_fps(self) -> set[str]:
        return {row[0] for row in self.conn.execute("SELECT fp FROM auto_wl_blacklist")}

    def whitelist_rows(self) -> list[tuple[str, str | None, float, str, str | None]]:
        return self.conn.execute(
            """SELECT fp, label, added_at, wl_source, auto_wl_reason
               FROM whitelist ORDER BY added_at DESC"""
        ).fetchall()

    def remember_whitelisted(
        self, fp: str, source: str = "device", reason: str | None = None
    ) -> bool:
        cur = self.conn.execute(
            """INSERT OR IGNORE INTO whitelist
               (fp, label, added_at, wl_source, auto_wl_reason)
               VALUES (?, NULL, ?, ?, ?)""",
            (fp, time.time(), source, reason),
        )
        self.commit()
        return cur.rowcount > 0

    def set_label(self, fp: str, label: str | None) -> None:
        self.conn.execute("UPDATE whitelist SET label = ? WHERE fp = ?", (label, fp))
        self.commit()

    def remove_whitelist(self, fp: str) -> None:
        self.conn.execute("DELETE FROM whitelist WHERE fp = ?", (fp,))
        self.commit()

    def mark_false_positive(self, fp: str, note: str | None = None) -> None:
        """Remove fp from whitelist and add to blacklist so it isn't re-auto-whitelisted."""
        self.conn.execute("DELETE FROM whitelist WHERE fp = ?", (fp,))
        self.conn.execute(
            "INSERT OR REPLACE INTO auto_wl_blacklist(fp, added_at, note) VALUES (?, ?, ?)",
            (fp, time.time(), note),
        )
        self.commit()

    # ---------- aggregated tables (L2 / L3) ----------

    def get_aggregated_through_date(self) -> str | None:
        row = self.conn.execute(
            "SELECT aggregated_through_date FROM retention_meta WHERE id = 1"
        ).fetchone()
        return row[0] if row else None

    def set_aggregated_through_date(self, d: str) -> None:
        self.conn.execute(
            "UPDATE retention_meta SET aggregated_through_date = ? WHERE id = 1", (d,)
        )
        self.commit()

    def upsert_daily_visit(
        self, fp: str, visit_date: str, first_seen: float, last_seen: float,
        n_obs: int, distinct_hours: int, was_new: bool,
    ) -> None:
        self.conn.execute(
            """INSERT OR REPLACE INTO daily_visits
               (fp, visit_date, first_seen_at, last_seen_at,
                n_observations, distinct_hours, was_new)
               VALUES (?,?,?,?,?,?,?)""",
            (fp, visit_date, first_seen, last_seen, n_obs, distinct_hours, int(was_new)),
        )

    def upsert_daily_total(
        self, d: str, total_unique: int, n_new: int, n_returning: int,
        hourly_counts: list[int], channel_counts: dict[str, int],
    ) -> None:
        self.conn.execute(
            """INSERT OR REPLACE INTO daily_totals
               (date, total_unique, n_new, n_returning, hourly_counts, channel_counts)
               VALUES (?,?,?,?,?,?)""",
            (d, total_unique, n_new, n_returning,
             json.dumps(hourly_counts), json.dumps(channel_counts)),
        )

    def fp_existed_before(self, fp: str, before_date: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM daily_visits WHERE fp = ? AND visit_date < ? LIMIT 1",
            (fp, before_date),
        ).fetchone()
        return row is not None

    def delete_daily_visits_before(self, before_date: str) -> int:
        cur = self.conn.execute(
            "DELETE FROM daily_visits WHERE visit_date < ?", (before_date,)
        )
        self.commit()
        return cur.rowcount

    # ---------- live stats (Today, mixes L1+L2) ----------

    def live_today_stats(self, returning_window_days: int) -> dict[str, int]:
        today_start, _ = _day_bounds(_today())
        today_str = _date_str(_today())
        returning_cutoff = _date_str(_today() - timedelta(days=returning_window_days))

        wl = self.whitelist_fps()
        fps_today = {
            row[0] for row in self.conn.execute(
                "SELECT DISTINCT fp FROM observations WHERE received_at >= ?",
                (today_start,),
            )
        }
        fps_today -= wl
        total = len(fps_today)
        if total == 0:
            return {"total": 0, "new": 0, "returning": 0}

        # Returning: fp existed in daily_visits before today within window.
        placeholders = ",".join("?" * len(fps_today))
        params = (*fps_today, today_str, returning_cutoff)
        returning_rows = self.conn.execute(
            f"""SELECT DISTINCT fp FROM daily_visits
                WHERE fp IN ({placeholders})
                  AND visit_date < ? AND visit_date >= ?""",
            params,
        ).fetchall()
        n_returning = len(returning_rows)
        n_new = total - n_returning
        return {"total": total, "new": n_new, "returning": n_returning}

    def yesterday_total(self) -> int:
        d = _date_str(_today() - timedelta(days=1))
        row = self.conn.execute(
            "SELECT total_unique FROM daily_totals WHERE date = ?", (d,)
        ).fetchone()
        return int(row[0]) if row else 0

    def total_observations_since(self, since: float) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) FROM observations WHERE received_at >= ?", (since,)
        ).fetchone()
        return int(row[0]) if row else 0

    def daily_totals_range(
        self, start_date: str, end_date: str
    ) -> list[tuple[str, int, int, int]]:
        rows = self.conn.execute(
            """SELECT date, total_unique, n_new, n_returning
               FROM daily_totals
               WHERE date >= ? AND date <= ?
               ORDER BY date""",
            (start_date, end_date),
        ).fetchall()
        return [(d, int(t), int(n), int(r)) for d, t, n, r in rows]

    def today_hourly(self, exclude_wl: bool = True) -> list[int]:
        """24 ints — unique non-WL fp count per hour of today (local time)."""
        today_start, _ = _day_bounds(_today())
        hours = [0] * 24
        wl_clause = (
            "AND fp NOT IN (SELECT fp FROM whitelist)" if exclude_wl else ""
        )
        rows = self.conn.execute(
            f"""SELECT CAST((received_at - ?) / 3600 AS INTEGER) AS h,
                       COUNT(DISTINCT fp) AS uniq
               FROM observations
               WHERE received_at >= ? {wl_clause}
               GROUP BY h""",
            (today_start, today_start),
        ).fetchall()
        for h, uniq in rows:
            h = int(h)
            if 0 <= h < 24:
                hours[h] = int(uniq)
        return hours

    def last_n_days_totals(self, n: int) -> list[tuple[str, int, int]]:
        """[(YYYY-MM-DD, weekday_idx, total_unique), ...] oldest first.

        For today, queries L1 live (excluding whitelist). For prior days,
        reads from L3 daily_totals (already excludes whitelist).
        """
        today = _today()
        out: list[tuple[str, int, int]] = []
        for i in range(n - 1, -1, -1):
            d = today - timedelta(days=i)
            if d == today:
                today_start, _ = _day_bounds(d)
                row = self.conn.execute(
                    """SELECT COUNT(DISTINCT fp) FROM observations
                       WHERE received_at >= ?
                         AND fp NOT IN (SELECT fp FROM whitelist)""",
                    (today_start,),
                ).fetchone()
                count = int(row[0]) if row else 0
            else:
                row = self.conn.execute(
                    "SELECT total_unique FROM daily_totals WHERE date = ?",
                    (d.isoformat(),),
                ).fetchone()
                count = int(row[0]) if row else 0
            out.append((d.isoformat(), d.weekday(), count))
        return out

    def frequency_segments(self, days_back: int) -> list[tuple[str, int]]:
        """Returns list of (segment_key, count). Caller translates keys via i18n."""
        cutoff = _date_str(_today() - timedelta(days=days_back))
        rows = self.conn.execute(
            """SELECT fp, COUNT(DISTINCT visit_date) AS visits
               FROM daily_visits
               WHERE visit_date >= ? AND visit_date < ?
               GROUP BY fp""",
            (cutoff, _date_str(_today())),
        ).fetchall()
        buckets = {"1_visit": 0, "2_3": 0, "4_7": 0, "8_plus": 0}
        for _fp, visits in rows:
            v = int(visits)
            if v <= 1:
                buckets["1_visit"] += 1
            elif v <= 3:
                buckets["2_3"] += 1
            elif v <= 7:
                buckets["4_7"] += 1
            else:
                buckets["8_plus"] += 1
        return list(buckets.items())

    # ---------- live devices (Debug tab) ----------

    def live_devices(self, window_seconds: int) -> list[LiveDevice]:
        cutoff = time.time() - window_seconds
        wl = {
            row[0]: row[1] for row in self.conn.execute(
                "SELECT fp, wl_source FROM whitelist"
            )
        }
        rows = self.conn.execute(
            """SELECT fp,
                      COUNT(*) AS n_obs,
                      MIN(received_at) AS first_seen,
                      MAX(received_at) AS last_seen,
                      AVG(rssi) AS avg_rssi,
                      GROUP_CONCAT(DISTINCT channel) AS channels_csv
               FROM observations
               WHERE received_at >= ?
               GROUP BY fp""",
            (cutoff,),
        ).fetchall()
        devices: list[LiveDevice] = []
        for fp, n_obs, first_seen, last_seen, avg_rssi, channels_csv in rows:
            # last rssi + last mac via small subquery
            tail = self.conn.execute(
                """SELECT rssi, mac FROM observations
                   WHERE fp = ? ORDER BY received_at DESC LIMIT 1""",
                (fp,),
            ).fetchone()
            last_rssi, last_mac = (int(tail[0]), str(tail[1])) if tail else (0, "")
            channels = (
                {int(c) for c in channels_csv.split(",")} if channels_csv else set()
            )
            devices.append(LiveDevice(
                fp=fp, mac=last_mac, last_rssi=last_rssi,
                avg_rssi=float(avg_rssi or 0), n_obs=int(n_obs),
                first_seen=float(first_seen), last_seen=float(last_seen),
                channels=channels, wl_source=wl.get(fp),
            ))
        return devices

    def auto_wl_candidates(
        self, window_hours: int, min_distinct_hours: int, min_observations: int
    ) -> list[tuple[str, int, int]]:
        """Return fps approaching the auto-WL threshold (for Debug visibility)."""
        cutoff = time.time() - window_hours * 3600
        return self.conn.execute(
            """SELECT fp,
                      COUNT(DISTINCT CAST(received_at / 3600 AS INTEGER)) AS hrs,
                      COUNT(*) AS n_obs
               FROM observations
               WHERE received_at >= ?
                 AND fp NOT IN (SELECT fp FROM whitelist)
                 AND fp NOT IN (SELECT fp FROM auto_wl_blacklist)
               GROUP BY fp
               HAVING hrs >= ? AND n_obs >= ?
               ORDER BY hrs DESC, n_obs DESC""",
            (cutoff, max(1, min_distinct_hours - 2), max(1, min_observations // 2)),
        ).fetchall()

    # ---------- maintenance metadata ----------

    def touch_maintenance_run(self) -> None:
        self.conn.execute(
            "UPDATE retention_meta SET last_maintenance_run = ? WHERE id = 1",
            (time.time(),),
        )
        self.commit()

    def get_last_backup_date(self) -> str | None:
        row = self.conn.execute(
            "SELECT last_backup_date FROM retention_meta WHERE id = 1"
        ).fetchone()
        return row[0] if row else None

    def set_last_backup_date(self, d: str) -> None:
        self.conn.execute(
            "UPDATE retention_meta SET last_backup_date = ? WHERE id = 1", (d,)
        )
        self.commit()
