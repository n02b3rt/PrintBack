from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class Observation:
    received_at: float
    t_us: int
    fp: str
    mac: str
    rssi: int
    channel: int
    ie_count: int
    new: bool
    whitelisted: bool

    @classmethod
    def from_json(cls, d: dict, received_at: float) -> "Observation":
        return cls(
            received_at=received_at,
            t_us=int(d["t"]),
            fp=str(d["fp"]),
            mac=str(d["mac"]),
            rssi=int(d["rssi"]),
            channel=int(d["ch"]),
            ie_count=int(d["ies"]),
            new=bool(d["new"]),
            whitelisted=bool(d["wl"]),
        )


@dataclass(frozen=True, slots=True)
class DailyTotal:
    date: str
    total_unique: int
    n_new: int
    n_returning: int
    hourly_counts: list[int]
    channel_counts: dict[str, int]


@dataclass(slots=True)
class LiveDevice:
    fp: str
    mac: str
    last_rssi: int
    avg_rssi: float
    n_obs: int
    first_seen: float
    last_seen: float
    channels: set[int] = field(default_factory=set)
    wl_source: str | None = None  # None | "device" | "manual" | "auto"
    distinct_hours_in_window: int = 0
