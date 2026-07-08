# Architecture: PrintBack (BLE + SD + Flutter)

This file describes the **target** architecture on the `refactor/ble-sd-flutter`
branch. `main` is today's working system (USB-CDC → Python/PySide6 desktop +
SQLite), see [README.md](../README.md) and
[docs/compliance/README.md](compliance/README.md). What's actually built on
this branch: [docs/PROGRESS.md](PROGRESS.md).

## System overview

Two nodes, zero third:

- **ESP32-C6**: sniffs WiFi probe requests, hashes on-chip, writes raw data
  to SD (30 days), computes hourly/daily aggregates on-device, serves ONLY
  those aggregates over BLE GATT.
- **Phone (Flutter)**: BLE central, caches received aggregates locally,
  shows the dashboard. Never computes anything from raw data, because it
  never receives any.

No cloud, no server, no third node, in keeping with the whole project's
ethos (docs/compliance/README.md).

## Diagram A: today (main branch)

```
[nearby phone]
      │ 802.11 probe request (mgmt frame)
      ▼
┌────────────────────────── ESP32-C6 (firmware/) ──────────────────────────┐
│ wifi_sniffer.c  promiscuous mode, channel-hop {1,6,11} every 400ms        │
│        │ on_packet()                                                     │
│        ▼                                                                 │
│ main.c: on_probe()                                                       │
│    ├─ fingerprint_from_ies()   SHA-256 over stable IEs → 8-byte hash     │
│    ├─ whitelist_contains(fp)   NVS: MANUAL button capture, not the auto- │
│    │                           heuristic compliance/README.md describes  │
│    │                           (see note below)                         │
│    ├─ tracker_observe(obs)     RAM hash table, 5-minute active window    │
│    └─ output_emit(obs,...)                                               │
│              │                                                           │
│              ▼  one JSON line per probe, USB-CDC 115200 baud             │
│  {"t":..,"fp":..,"mac":..,"rssi":..,"ch":..,"ies":..,"new":..,"wl":..}   │
└──────────────────────────────┬─────────────────────────────────────────┘
                                 │ USB cable
                                 ▼
                  app/ (Python/PySide6 desktop, operator's computer)
                  JSON → SQLite (L1 raw 30d / L2 daily-per-fp 365d /
                  L3 daily totals ∞) → dashboard
```

**Note on the documentation/code gap:** `docs/compliance/README.md` describes
auto-whitelist ("6+ hours in an 8h window → automatically whitelisted"). This
mechanism **doesn't exist in the firmware**: today the whitelist is built
exclusively by manually holding the button (`ui.c`, `UI_EVENT_LONG_PRESS`,
3000ms). We're not carrying that inaccuracy into the new architecture
without a conscious decision: if the auto-heuristic gets built, it's a
separate, named phase, not something that's "already" happening.

## Diagram B: target (this branch, after Phases 2-6)

```
[nearby phone]
      │ 802.11 probe request
      ▼
┌───────────────────────────────── ESP32-C6 ─────────────────────────────────┐
│ wifi_sniffer.c            (unchanged)                                      │
│ main.c: on_probe() → fingerprint_from_ies() → whitelist_contains()         │
│        ▼                                                                   │
│ tracker.c                 (unchanged: RAM, 5-min window, "who's here now")  │
│        ▼                                                                   │
│ [NEW] sd_storage: write sd_raw_record_t (16B, NO MAC)                      │
│        → /sdcard/logs/raw/YYYYMMDD.bin        (30-day rolling purge)       │
│        ▼  once/hour + once/day on rollover                                 │
│ [NEW] aggregation: unique_count / returning_count from today's raw         │
│    kanon_hourly_publishable(unique_count)?  (already done: firmware/main/  │
│    kanon.c)                                                                 │
│       yes → append an hourly aggregate_record_t (k_anonymity_applied=0)    │
│             → /sdcard/logs/stats/hourly/YYYYMMDD.bin                       │
│       no → add to running daily total, k_anonymity_applied=1               │
│             → /sdcard/logs/stats/today.bin (mutable) → daily.bin on        │
│               rollover                                                     │
│        ▼                                                                   │
│ [NEW] BLE GATT server (ESP_COEX_SW_COEXIST_ENABLE, one HP core,            │
│        priorities alongside WiFi sniff, see "Task scheduling")            │
│    STATS (read+notify): one aggregate JSON per notification                │
│    CONFIG (read-only): thresholds (RSSI, returning window)                 │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                     │ BLE GATT, bonded (D5: button + bonding)
                                     ▼
                       mobile/ (Flutter, flutter_blue_plus)
                       STATS subscription → local aggregate cache → dashboard
                       zero raw data, zero per-client identifiers
```

## Division of responsibility

The device does everything: sniffing, hashing, dedup, ALL aggregation,
k-anonymity enforcement, retention/purge. Phone: BLE central + pairing/
bonding, local aggregate cache, dashboard rendering, writing CONFIG values.
The phone **never** computes an aggregate from raw data, because it never
receives raw data. This is a hard, unconditional rule (docs/DECISIONS.md D3).

## Task scheduling

The ESP32-C6 has **one HP core (RISC-V, up to 160 MHz)** plus a separate
LP co-processor that doesn't run general FreeRTOS tasks (only a minimal
wake-source firmware in deep sleep), so there's no two-core split for
scheduling here. Today's FreeRTOS priorities are: `ui_task` (5),
`channel_hopper` (4), `housekeeper` (3), `usb_link_monitor` (2), all
plain `xTaskCreate` with no pinning. The target adds the BLE stack +
SD/aggregation task; exact priorities are a Phase 4 implementation
detail, not fixed here.

## Wall-clock time

The device has no real-time clock, only `esp_timer_get_time()`
(microseconds since boot, resets on every reboot), zero RTC, zero
WiFi-STA/NTP (deliberately, per the "no network calls" rule). To be able
to name SD files by calendar date: **the phone sends the current unix
time on every BLE connection** (it already has to be physically present
for pairing/syncing anyway, D5). The device keeps `esp_timer_get_time()`
as a monotonic source + an offset corrected on every sync. Before the
first pairing: no meaningful calendar date, behavior for that case is a
Phase 2 implementation detail. Decision and rationale: docs/DECISIONS.md D6.

## SD layout

- `/sdcard/logs/raw/YYYYMMDD.bin`: raw, fixed-length 16-byte records,
  append-only, 30-day rolling purge (see DATA_MODEL.md). No dashes: FAT
  short (8.3) filenames don't fit `YYYY-MM-DD`, see docs/LEARNINGS.md.
- `/sdcard/logs/stats/hourly/YYYYMMDD.bin`: hourly aggregates,
  append-only, never deleted (aggregates aren't personal data, D3).
- `/sdcard/logs/stats/today.bin`: one mutable record, "day in progress",
  lets BLE serve "today so far" without waiting for midnight.
- `/sdcard/logs/stats/daily.bin`: finalized days, append-only, unlimited retention.

## BLE GATT (sketch)

One service, two characteristics ship in Phase 4 (UUIDs: docs/DATA_MODEL.md):

- **STATS** (read + notify): one aggregate JSON row per notification,
  format: docs/DATA_MODEL.md.
- **CONFIG** (read-only in Phase 4): RSSI threshold, "returning" window.

**PAIRING_STATUS** (read + notify, pairing mode state) and CONFIG's write
side (RSSI threshold, returning window, reset trigger) are Phase 5 scope:
both need the button + bonding state machine (docs/DECISIONS.md D5) to
exist first, so implementing them in Phase 4 would be either a meaningless
stub or an unauthenticated write any nearby BLE device could hit.

## Coexistence

WiFi monitor mode + BLE: OK, software coex (`ESP_COEX_SW_COEXIST_ENABLE`),
see docs/DECISIONS.md D4. WiFi + Thread/802.15.4 on the same radio: NO,
confirmed on another project, see docs/LEARNINGS.md. Doesn't apply to this
project directly (no Thread here), but the rule holds forever.

## Pairing/bonding

Physical button + BLE bonding in NVS (docs/DECISIONS.md D5). Today the
button only knows one gesture (`UI_EVENT_LONG_PRESS`, 3000ms, arms
whitelist capture); adding a second gesture for entering pairing mode is
a Phase 5 implementation detail, not designed here.
