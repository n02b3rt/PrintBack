from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from .config import Config
from .store import Store, _date_str, _day_bounds, _today


@dataclass(slots=True)
class MaintenanceReport:
    aggregated_days: int = 0
    l1_purged: int = 0
    l2_purged: int = 0
    auto_wl_added: list[str] | None = None
    backup_created: str | None = None

    def has_changes(self) -> bool:
        return bool(
            self.aggregated_days
            or self.l1_purged
            or self.l2_purged
            or self.auto_wl_added
            or self.backup_created
        )


class Maintenance:
    def __init__(self, store: Store, config: Config, app_dir: Path) -> None:
        self.store = store
        self.config = config
        self.app_dir = app_dir

    def run_all(self) -> MaintenanceReport:
        report = MaintenanceReport()
        report.aggregated_days = self.aggregate_completed_days()
        report.auto_wl_added = self.detect_auto_wl()
        report.l1_purged = self.purge_l1()
        report.l2_purged = self.purge_l2()
        report.backup_created = self.maybe_backup()
        self.store.touch_maintenance_run()
        return report

    # ---------- L1 -> L2 / L3 aggregation ----------

    def aggregate_completed_days(self) -> int:
        last_str = self.store.get_aggregated_through_date()
        today = _today()
        start = (
            date.fromisoformat(last_str) + timedelta(days=1)
            if last_str
            else self.store.earliest_observation_date()
        )
        if start is None or start >= today:
            return 0

        count = 0
        d = start
        while d < today:
            self._aggregate_day(d)
            count += 1
            d += timedelta(days=1)

        self.store.set_aggregated_through_date(_date_str(today - timedelta(days=1)))
        return count

    def _aggregate_day(self, d: date) -> None:
        day_start, day_end = _day_bounds(d)
        d_str = _date_str(d)
        wl = self.store.whitelist_fps()

        per_fp = self.store.conn.execute(
            """SELECT fp,
                      MIN(received_at)                      AS first_seen,
                      MAX(received_at)                      AS last_seen,
                      COUNT(*)                              AS n_obs,
                      COUNT(DISTINCT CAST((received_at - ?) / 3600 AS INTEGER)) AS hrs
               FROM observations
               WHERE received_at >= ? AND received_at < ?
               GROUP BY fp""",
            (day_start, day_start, day_end),
        ).fetchall()

        unique_non_wl = 0
        n_new = 0
        for fp, first_seen, last_seen, n_obs, hrs in per_fp:
            if fp in wl:
                continue
            was_new = not self.store.fp_existed_before(fp, d_str)
            self.store.upsert_daily_visit(
                fp=fp, visit_date=d_str,
                first_seen=float(first_seen), last_seen=float(last_seen),
                n_obs=int(n_obs), distinct_hours=int(hrs), was_new=was_new,
            )
            unique_non_wl += 1
            if was_new:
                n_new += 1

        # returning = saw on >= 1 day in the (returning_window) days prior to d
        ret_cutoff = _date_str(d - timedelta(days=self.config.returning_window_days))
        n_returning_row = self.store.conn.execute(
            """SELECT COUNT(DISTINCT today.fp)
               FROM daily_visits today
               WHERE today.visit_date = ?
                 AND EXISTS (
                   SELECT 1 FROM daily_visits prior
                   WHERE prior.fp = today.fp
                     AND prior.visit_date < today.visit_date
                     AND prior.visit_date >= ?
                 )""",
            (d_str, ret_cutoff),
        ).fetchone()
        n_returning = int(n_returning_row[0]) if n_returning_row else 0

        hourly = [0] * 24
        for h, uniq in self.store.conn.execute(
            """SELECT CAST((received_at - ?) / 3600 AS INTEGER) AS h,
                      COUNT(DISTINCT fp) AS uniq
               FROM observations
               WHERE received_at >= ? AND received_at < ?
                 AND fp NOT IN (SELECT fp FROM whitelist)
               GROUP BY h""",
            (day_start, day_start, day_end),
        ).fetchall():
            h = int(h)
            if 0 <= h < 24:
                hourly[h] = int(uniq)

        ch_counts = {
            str(int(ch)): int(n)
            for ch, n in self.store.conn.execute(
                """SELECT channel, COUNT(*) FROM observations
                   WHERE received_at >= ? AND received_at < ?
                   GROUP BY channel""",
                (day_start, day_end),
            ).fetchall()
        }

        self.store.upsert_daily_total(
            d=d_str, total_unique=unique_non_wl,
            n_new=n_new, n_returning=n_returning,
            hourly_counts=hourly, channel_counts=ch_counts,
        )
        self.store.commit()

    # ---------- purge ----------

    def purge_l1(self) -> int:
        cutoff = time.time() - self.config.l1_retention_days * 86400
        return self.store.delete_observations_before(cutoff)

    def purge_l2(self) -> int:
        cutoff = _date_str(_today() - timedelta(days=self.config.l2_retention_days))
        return self.store.delete_daily_visits_before(cutoff)

    # ---------- auto-whitelist ----------

    def detect_auto_wl(self) -> list[str]:
        now = time.time()
        cutoff = now - self.config.auto_wl_window_hours * 3600
        rows = self.store.conn.execute(
            """SELECT fp,
                      COUNT(DISTINCT CAST(received_at / 3600 AS INTEGER)) AS hrs,
                      COUNT(*) AS n_obs
               FROM observations
               WHERE received_at >= ?
                 AND fp NOT IN (SELECT fp FROM whitelist)
                 AND fp NOT IN (SELECT fp FROM auto_wl_blacklist)
               GROUP BY fp
               HAVING hrs >= ? AND n_obs >= ?""",
            (
                cutoff,
                self.config.auto_wl_min_distinct_hours,
                self.config.auto_wl_min_observations,
            ),
        ).fetchall()

        added: list[str] = []
        for fp, hrs, n_obs in rows:
            reason = (
                f"{int(hrs)}/{self.config.auto_wl_window_hours}h active, "
                f"{int(n_obs)} obs"
            )
            if self.store.remember_whitelisted(fp, source="auto", reason=reason):
                added.append(fp)
        return added

    # ---------- backup ----------

    def maybe_backup(self) -> str | None:
        today_str = _date_str(_today())
        if self.store.get_last_backup_date() == today_str:
            return None
        backups_dir = self.app_dir / "backups"
        backups_dir.mkdir(parents=True, exist_ok=True)
        target = backups_dir / f"printback-{today_str}.db"
        # SQLite VACUUM INTO requires absolute path with forward slashes for safety.
        # Use double single-quotes to escape any '.
        target_sql = str(target).replace("'", "''")
        # Commit and checkpoint WAL so backup is fully consistent.
        self.store.commit()
        self.store.conn.execute("PRAGMA wal_checkpoint(FULL)")
        if target.exists():
            target.unlink()
        self.store.conn.execute(f"VACUUM INTO '{target_sql}'")
        self.store.set_last_backup_date(today_str)

        # rotate
        kept = self.config.backup_keep_days
        backups = sorted(backups_dir.glob("printback-*.db"))
        for old in backups[:-kept] if kept > 0 else backups:
            try:
                old.unlink()
            except OSError:
                pass
        return target.name
