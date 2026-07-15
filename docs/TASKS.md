# docs/TASKS.md: detailed task plan (PrintBack rebuild: USB/desktop → BLE + SD + Flutter)

Context and hard rules: @docs/DECISIONS.md, @docs/compliance/README.md
Before starting EVERY phase: read @docs/LEARNINGS.md.
After finishing EVERY phase: update @docs/PROGRESS.md, make a commit,
ask the user before moving on, don't chain phases automatically.

The project name stays **PrintBack**, no rebranding.

---

## PHASE 1: Base documentation (no code changes)

Goal: have a written contract before anything moves in firmware.

Tasks:
1. Create `docs/ARCHITECTURE.md`: description of the whole system: C6
   (sniff+SD+BLE), phone (Flutter, aggregate cache), data flow diagram
   (probe request → hash → SD raw → hourly aggregation → BLE → phone).
2. Create `docs/DATA_MODEL.md`: exact formats:
   - raw record on SD (fields: timestamp, fp/hash IE, rssi, channel,
     is_new/is_returning, is_whitelisted)
   - aggregate record (date, hour_or_day, unique_count, returning_count,
     k_anonymity_applied: bool)
   - payload BLE characteristic STATS (JSON/CBOR schema)
3. Update `README.md`: new architecture instead of USB+desktop, new
   example payload (WITHOUT the "mac" field).
4. Don't touch code in this phase.

Acceptance criteria: the files exist, are consistent with
@docs/DECISIONS.md, the user reviewed and accepted them.

---

## PHASE 2: Firmware, SD card logging

Goal: data goes to SD instead of (or alongside, temporarily) USB.

Tasks:
1. Add a `firmware/components/sd_storage/` module: SPI driver (sdspi),
   card init, FAT mount.
2. Define the directory structure: `/sdcard/logs/raw/YYYY-MM-DD.bin` (or
   .csv, decide and record the choice + rationale in docs/DECISIONS.md).
3. Write a raw record for every captured probe request (format per
   docs/DATA_MODEL.md), do NOT write a raw MAC anywhere yet, only fp (IE
   hash), per the existing hashing mechanism.
4. Rolling purge: at the start of the day (or on boot + once-daily
   timer) delete raw files older than 30 days.
5. Test: plug in the card, check files get created, rotate daily, and
   old ones get deleted (you can test with a shorter window, e.g. 2 min
   instead of 30 days, so you don't wait a month, then restore 30 days).

Note: if you hit an SPI pin conflict with the existing whitelist
LED/button, don't guess, write it up in LEARNINGS.md and ask the user
about the GPIO mapping on the board they actually have.

Acceptance criteria: raw logs land on SD in the correct format, rotation
and purge work, no existing mechanism (WiFi sniff, whitelist heuristic,
watchdogs) got broken.

---

## PHASE 3: Firmware, on-device aggregation + removing raw MAC from the payload

Goal: the device computes stats itself, raw data never leaves SD.

Tasks:
1. Remove the "mac" field from any existing JSON sent over USB/serial
   (the existing code has it, it has to disappear completely).
2. Write an aggregation module: every hour, count unique_count and
   returning_count from today's logs (returning = fp seen earlier within
   the window set in docs/compliance/README.md, e.g. 24h/7 days, confirm
   the exact definition with the user if it isn't recorded yet).
3. Implement the k-anonymity threshold: if unique_count in a given hour
   < 5, do NOT publish the hourly record, instead add it to the daily
   aggregate (the daily resolution always publishes, regardless of the
   threshold). Already done: `firmware/main/kanon.c`
   (`kanon_hourly_publishable`), tested in
   `firmware/test_host/test_kanon.c`, use that instead of writing the
   threshold from scratch.
4. Write aggregates as separate, smaller records (SD, a separate
   file/directory from raw, e.g. `/sdcard/logs/stats/`), this is the
   only data that reaches BLE.
5. Account for the auto-whitelist heuristic from the existing code,
   whitelisted devices do NOT count toward unique/returning count.

Acceptance criteria: no raw MAC/per-client hash leaves the aggregation
module, hourly aggregates respect the k-anonymity threshold, whitelist
works like before.

---

## PHASE 4: Firmware, BLE GATT server

Goal: the device serves aggregates over BLE, coexisting with WiFi
monitor mode.

Tasks:
1. Enable `ESP_COEX_SW_COEXIST_ENABLE` (verified name, see
   docs/DECISIONS.md D4; ESP-IDF auto-enables it once WiFi and Bluetooth
   are both compiled in), configure the BLE stack alongside the existing
   WiFi monitor mode + channel hopping.
2. Define a GATT service. Two characteristics ship in this phase (UUIDs
   in docs/DATA_MODEL.md):
   - STATS (read + notify): serves aggregates per the DATA_MODEL.md
     schema, chunked to the current MTU
   - CONFIG (read-only in this phase): RSSI threshold, "returning" window
   PAIRING_STATUS (read/notify) and CONFIG's write side are deferred to
   Phase 5: both need the bonding/pairing state machine to exist first
   (PAIRING_STATUS reports on it; CONFIG-write needs it to gate
   unauthenticated writes from any nearby BLE device), so implementing
   either now would be either a meaningless stub or a real security gap.
3. Task/priority layout: the ESP32-C6 has a single HP core (RISC-V), so
   there's no core split to do (docs/ARCHITECTURE.md "Task scheduling").
   WiFi sniff+hop and the BLE stack + aggregation + SD writes all run as
   FreeRTOS tasks time-sliced on that one core; `ESP_COEX_SW_COEXIST_ENABLE`
   arbitrates radio access in software between the two stacks. Check the
   current task priorities in `firmware/main/main.c` and add the NimBLE
   host task at a sensible priority, don't guess from scratch.
4. Test: connect with any generic BLE scanner (e.g. nRF Connect) and
   verify the STATS and CONFIG characteristics return valid JSON, and WiFi
   sniffing still catches probe requests without noticeable degradation
   (count packets/min before and after enabling BLE, record the result
   in LEARNINGS.md).

Acceptance criteria: BLE and WiFi monitor mode run simultaneously
without significant packet loss, characteristics return correct data.

---

## PHASE 5: Firmware, pairing (button + bonding)

Goal: secure but convenient pairing with the phone.

Tasks:
1. Reuse the existing tact switch (currently used for whitelist
   capture), extend its function to entering pairing mode (e.g. long
   hold vs short click, distinguish by duration).
2. Pairing mode active for a limited time (e.g. 60s), signaled by the
   existing RGB LED (a different color/pulse than the whitelist state).
3. Implement BLE bonding: pairing keys in NVS, subsequent connections
   from an already-paired phone are automatic, no need to press the
   button again.
4. Test: pair once, restart the device, check that reconnecting with the
   same phone doesn't require the button.

Acceptance criteria: pairing requires physical access to the device,
bonding survives a restart, an unpaired phone has no access to the
characteristics.

---

## PHASE 6: Mobile app, Flutter skeleton

Goal: the app connects, syncs aggregates, shows a basic dashboard.

Tasks:
1. New `mobile/` directory: a Flutter project, add `flutter_blue_plus`
   (or `flutter_reactive_ble`, decide and record the choice in
   DECISIONS.md).
2. Pairing screen: BLE scan, "press the button on the device"
   instructions, bonding handling.
3. After pairing: subscribe to the STATS characteristic, write to a
   local database (SQLite/Hive), EXCLUSIVELY the aggregate fields (date,
   hour/day, unique_count, returning_count), zero per-client identifiers.
4. Basic dashboard: daily/hourly chart, a simple new/returning view
   (doesn't need to be a final design, needs to be functional).
5. Settings screen: change the RSSI threshold / returning window via the
   CONFIG characteristic.

Acceptance criteria: the app pairs, syncs aggregates, shows data on a
chart, no raw/identifiable data reaches the phone's local database.

---

## PHASE 7: Final documentation

Tasks:
1. Update `docs/compliance/README.md` with a full description of the
   new model (what, where, how long: SD 30 days raw, phone aggregates
   unlimited, k-anonymity).
2. Update `README.md`: final architecture description, quick start for
   the new version, updated screenshots/examples.
3. Keep and update the "Honest limits" section, add a note about
   k-anonymity threshold limitations at very low traffic.
4. Review `docs/LEARNINGS.md`: if there are stale entries (problems no
   longer relevant after the refactor), mark them RESOLVED, don't delete.

Acceptance criteria: the documentation describes the repo's actual state
after the rebuild, a new contributor (or you in six months) understands
all of it without asking.

---

## PHASE 8: production sync, multi-device, redesign

Not part of the original refactor plan - added after real-phone testing
of Phase 6 surfaced concrete gaps (see docs/PROGRESS.md for the request
history). Lives on `feature/sync-multidevice-redesign`, not
`refactor/ble-sd-flutter` (that branch is done and merged).

Tasks:
1. Firmware: SYNC characteristic, backlog replay of `stats/daily.bin`
   (docs/DATA_MODEL.md "BLE SYNC payload", docs/DECISIONS.md D10).
2. Mobile foundations: light/dark theming, `shared_preferences`,
   device-scoped local db (`device_id` column).
3. Auto-reconnect on launch (`FlutterBluePlus.systemDevices`) instead of
   a mandatory manual scan every time; device switching in Settings.
4. Bottom-nav shell (Dashboard/Statystyki/Ustawienia), SYNC wiring
   (automatic on connect + manual "Synchronizuj teraz"), new Statystyki
   screen (weekly/monthly totals, returning rate, day-of-week pattern,
   best-effort peak hour) computed entirely from already-synced
   aggregates - no new per-client data, ever.
5. Visual redesign (restrained dark theme, flat light theme) across all
   screens, interactive charts (tap a bar for detail).

Acceptance criteria: app reopens and reconnects without a manual scan,
multiple bonded devices can be listed and switched between, Statystyki
shows real multi-day numbers after a sync, no raw/per-client data
anywhere in the local db or on the wire.

---

## Post-soak backlog: auto-whitelist refinements

Two improvements to the staff/fixed-device auto-whitelist, both deferred
because they change the frozen firmware and a reflash would reset the
30-day soak. Do them once the soak finishes, together with the next flash.

1. **Firmware: add an observation-count gate.** Today `wl_auto.c`
   qualifies a fingerprint purely on ">= 6 distinct hours in an 8h rolling
   window". `docs/compliance/README.md`'s config already names
   `auto_wl_min_observations: 30`, but the firmware doesn't enforce it.
   Require ">= 6 distinct hours AND >= N observations" so a device is only
   excluded once it's clearly fixed infrastructure/staff, not a visitor
   who happened to linger across several hours. Keep the host test
   (`test_wl_auto.c`) and add cases for the new gate.

2. **App: surface an auto-whitelist count (a count, never a list).** The
   phone must never receive a per-client identifier (docs/DECISIONS.md
   D3 - even a hashed MAC is personal data and stays on the device), so
   this is strictly an aggregate count ("N devices auto-excluded as
   staff/fixed"), carried via a new read-only STATUS field on the device
   and shown in the app. Gives the operator visibility and trust without
   exposing any device identity.

The lawfulness of the auto-whitelist itself is data-minimisation-positive
per `docs/compliance/README.md`, but the definitive read stays with the
lawyer / operator DPIA - not decided here. This belongs in the Phase 7
compliance/legal pass before a pilot.

## Post-soak backlog: hold-to-restart gesture

`firmware/main/ui.c` now reboots the device on a ~10s button hold
(`RESTART_HOLD_MS`), with the LED signalling it - an accelerating red
blink from `RESTART_WARN_MS` (5s), then a white confirm flash at 10s
before `esp_restart()`. This replaces the old "unplug from power" field
recovery (the app's restart instruction now describes the hold, not the
unplug). Not yet flashed: it changes the frozen firmware, so it ships
with the next reflash after the soak, together with the auto-whitelist
refinements above. Until then the on-device gesture isn't live even
though the app already documents it.
