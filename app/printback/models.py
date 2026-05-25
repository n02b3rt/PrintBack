from __future__ import annotations

from dataclasses import dataclass


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
