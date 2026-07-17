# Architecture: PrintBack (BLE + SD + Flutter)

This is the architecture on `main`, built and running. The USB-CDC →
Python/PySide6 desktop system it replaced is gone from the description here;
its code survives under `app/` for reference only. See
[README.md](../README.md) for the overview,
[docs/compliance/README.md](compliance/README.md) for the data/privacy side,
and [docs/PROGRESS.md](PROGRESS.md) for how it got here.

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

## Diagram: the data path

```
[nearby phone]
      │ 802.11 probe request (mgmt frame)
      ▼
┌───────────────────────────────── ESP32-C6 ─────────────────────────────────┐
│ wifi_sniffer.c  promiscuous mode, channel-hop {1,6,11} every 400ms         │
│        │ on_packet(): extract + hash only, then queue and return.          │
│        │ Runs in the WiFi driver's own time-critical context, so it does    │
│        │ no I/O at all - see "Capture is decoupled from I/O" below.        │
│        ▼  bounded FreeRTOS queue                                           │
│ probe_proc_task → main.c: on_probe()                                       │
│    ├─ fingerprint_from_ies()   SHA-256 over stable IEs → 8-byte hash       │
│    ├─ whitelist_contains(fp)   NVS: manual capture + wl_auto.c heuristic   │
│    ├─ tracker_observe(obs)     RAM hash table, 5-minute active window      │
│    ├─ sd_storage: write sd_raw_record_t (16B, no MAC field exists)         │
│    │     → /sdcard/logs/raw/YYYYMMDD.bin      (30-day rolling purge)       │
│    └─ output_emit(obs,...)     one JSON line per probe, USB-CDC 115200,    │
│                                bench debugging only, no MAC in it          │
│        ▼  once/hour + once/day on rollover                                 │
│ aggregate.c: unique_count / returning_count from today's raw               │
│    kanon_hourly_publishable(unique_count)?   (firmware/main/kanon.c)       │
│       yes → append an hourly aggregate_record_t (k_anonymity_applied=0)    │
│             → /sdcard/logs/stats/hourly/YYYYMMDD.bin                       │
│       no → add to running daily total, k_anonymity_applied=1               │
│             → /sdcard/logs/stats/today.bin (mutable) → daily.bin on        │
│               rollover                                                     │
│        ▼                                                                   │
│ ble_gatt.c: NimBLE GATT server (ESP_COEX_SW_COEXIST_ENABLE, one HP core)   │
│    one service, five characteristics - see "BLE GATT" below               │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                     │ BLE GATT, bonded (D5: button + bonding)
                                     ▼
                       mobile/ (Flutter, flutter_blue_plus)
                       STATS subscription + SYNC replay → local aggregate
                       cache → dashboard.
                       Zero raw data, zero per-client identifiers.
```

**Auto-whitelist:** `wl_auto.c` (a pure, host-tested accumulator) tracks each
fingerprint's distinct in-window hours and total observations, and on
qualification calls `whitelist_add()` from `on_probe()`. Two gates, both must
pass: 6+ distinct hours within a rolling 8h window **and** 30+ total
observations - the observation gate exists so a device that merely drifts
past the door at the same time each hour doesn't get whitelisted out of the
counts. It runs alongside the manual button capture (`ui.c`,
`UI_EVENT_LONG_PRESS`, 3000ms). Thresholds are Kconfig (`PRINTBACK_AUTO_WL_*`).

## Capture is decoupled from I/O

`on_packet()` does only fast CPU work (field extraction, IE hashing) and
pushes the observation into a bounded queue with a zero timeout - if the
queue is ever full it drops and counts (`wifi_sniffer_dropped_count()`,
logged by `housekeeper()`) rather than blocking. `probe_proc_task` is the
only caller of `on_probe()`, so every blocking operation (the SD write's
`fflush()`+`fsync()`, the USB-CDC `printf()`) happens off the WiFi driver's
callback path. However slow SD or USB gets, it can back up the queue but
cannot stall capture. See docs/LEARNINGS.md (2026-07-11) for the symptom
that motivated this.

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
scheduling here. FreeRTOS priorities: `ui_task` (5), `channel_hopper` (4),
`housekeeper` (3), `probe_proc_task` (3), `usb_link_monitor` (2), all plain
`xTaskCreate` with no pinning. NimBLE runs its own host task, started by
`ble_gatt_start()`.

## Wall-clock time

The device has no real-time clock, only `esp_timer_get_time()`
(microseconds since boot, resets on every reboot), zero RTC, zero
WiFi-STA/NTP (deliberately, per the "no network calls" rule). To be able
to name SD files by calendar date: **the phone sends the current unix
time on every BLE connection** (it already has to be physically present
for pairing/syncing anyway, D5). The device keeps `esp_timer_get_time()`
as a monotonic source + an offset corrected on every sync. Before the first
sync it falls back to a build-time Kconfig date, so files still get named and
nothing is lost - the dates are simply wrong until a phone corrects them, and
the aggregates catch up on the next connection. Note the consequence: any
reset drops the correction and the device silently reverts to that fallback
until a phone reconnects, which is why the app retries a dropped connection
on its own (docs/LEARNINGS.md, 2026-07-11). Decision and rationale:
docs/DECISIONS.md D6.

## SD layout

- `/sdcard/logs/raw/YYYYMMDD.bin`: raw, fixed-length 16-byte records,
  append-only, 30-day rolling purge (see DATA_MODEL.md). No dashes: FAT
  short (8.3) filenames don't fit `YYYY-MM-DD`, see docs/LEARNINGS.md.
- `/sdcard/logs/stats/hourly/YYYYMMDD.bin`: hourly aggregates,
  append-only, never deleted (aggregates aren't personal data, D3).
- `/sdcard/logs/stats/today.bin`: one mutable record, "day in progress",
  lets BLE serve "today so far" without waiting for midnight.
- `/sdcard/logs/stats/daily.bin`: finalized days, append-only, unlimited retention.

## BLE GATT

One service, five characteristics (UUIDs and payload formats:
docs/DATA_MODEL.md). Every write requires a bonded/encrypted link
(`BLE_GATT_CHR_F_WRITE_ENC`); reads don't, because the connection whitelist
already gates who can connect at all.

- **STATS** (read + notify): one aggregate JSON row per notification. The
  read returns "today so far", which is what a freshly-connected phone gets
  before any rollover happens.
- **CONFIG** (read + write): RSSI floor, "returning" window.
- **TIME_SYNC** (write): the phone's current unix time, sent on every
  connection - see "Wall-clock time".
- **SYNC** (write): asks the device to replay its backlog, daily rows first,
  then today's hourly rows (docs/DECISIONS.md D10).
- **STATUS** (read): device health - uptime, free heap, whitelist size as a
  count only, never its contents.

**PAIRING_STATUS** (pairing mode state) isn't implemented - no clear need
for it beyond the LED, which already signals pairing mode locally.

## Coexistence

WiFi monitor mode + BLE: OK, software coex (`ESP_COEX_SW_COEXIST_ENABLE`),
see docs/DECISIONS.md D4. WiFi + Thread/802.15.4 on the same radio: NO,
confirmed on another project, see docs/LEARNINGS.md. Doesn't apply to this
project directly (no Thread here), but the rule holds forever.

## Pairing/bonding

Physical button + BLE bonding in NVS (docs/DECISIONS.md D5). A short
click (`UI_EVENT_SHORT_CLICK`) opens a 60-second pairing window
(`ui.c`'s existing 3000ms long-press for whitelist-arm is unchanged, a
second, independent gesture). Physical-access gating is enforced at the
link layer, not the SM/pairing layer: the controller's connection
whitelist only accepts already-bonded peers outside the window
(`ble_gap_wl_set()`, `BLE_HCI_ADV_FILT_CONN`), switching to accept-anyone
(`BLE_HCI_ADV_FILT_NONE`) only while the window is open. Just Works
(`BLE_SM_IO_CAP_NO_IO`, no display on this device) has no app-level hook
to refuse an incoming pairing request on its own, so the whitelist is
what actually enforces "physical access required to pair", not the
pairing procedure itself.
