# Progress: PrintBack refactor (BLE + SD + Flutter)

- [x] Phase 0: starting documentation (project rules index, docs/DECISIONS.md,
      docs/LEARNINGS.md, docs/PROGRESS.md, docs/TASKS.md,
      docs/ARCHITECTURE.md/docs/DATA_MODEL.md skeletons, local rules notes) (2026-07-02)
- [x] Phase 0.5: tooling (`refactor/ble-sd-flutter` branch, dev_cycle.py,
      pre-commit MAC-leak guard, host test harness + kanon.c example) (2026-07-02)
- [x] Phase 1: docs/ARCHITECTURE.md, docs/DATA_MODEL.md, README.md,
      docs/DECISIONS.md D6/D7, see docs/TASKS.md (2026-07-04)
- [x] Phase 2: SD card logging (2026-07-08). SPI SD card mount
      (`sd_storage.c`), raw record write path, path/purge logic + host
      tests (`sd_paths.c`), Kconfig pins/retention/wallclock fallback,
      wired into `on_probe()`. Verified on real hardware: mount succeeds
      (`SD ready: MSSD0, 59700MB`), a raw record write lands
      (`sd_bytes=16` after one record), rotation opens a new day's file,
      and purge deletes an aged-out file (clock advanced 2 days,
      retention set to 1 day for the test: `purge: deleted 1 raw log
      file(s)`). Existing mechanisms (WiFi sniff, whitelist, watchdogs)
      unaffected. Hit and fixed one real bug along the way: FAT short
      (8.3) filenames don't fit `YYYY-MM-DD.bin`, switched to
      `YYYYMMDD.bin`, see docs/LEARNINGS.md.
- [x] Phase 3: on-device aggregation, drop raw MAC (2026-07-08). `"mac"`
      field gone from the USB JSON line for good (`output.c`). New
      `aggregate.c`: hourly scan of today's raw log, dedup, k-anonymity
      gate (`kanon_hourly_publishable()`), 30-day returning-window
      history set rebuilt once per day, writes to
      `stats/hourly/YYYYMMDD.bin` (only when publishable) and
      `stats/today.bin` (always, running total), folded into
      `stats/daily.bin` on rollover. `sd_paths.c` extended with the stats
      path formatters and an hour-of-day helper, host tests updated.
      Wired into the existing housekeeper tick (hour/day-rollover check,
      same pattern as Phase 2's SD day-rollover). Verified on real
      hardware with synthetic probes (no real WiFi traffic available to
      test with): `hour 10: unique=6 returning=0 published=yes`, then
      `hour 23: unique=6 ... published=yes` immediately followed by
      `daily rollover: history set rebuilt, 6 unique fp over last 30
      days`. Hit and fixed a real bug along the way: aggregation
      couldn't see its own SD writes (missing `stats/` directories +
      `fflush()` alone isn't enough on FatFs, needs `fsync()` too), see
      docs/LEARNINGS.md.
- [x] Phase 4: BLE GATT server (2026-07-08). NimBLE enabled alongside the
      existing WiFi sniffer (`CONFIG_BT_NIMBLE_ENABLED`,
      `CONFIG_ESP_COEX_SW_COEXIST_ENABLE` - corrected from the wrong
      `CONFIG_SW_COEXIST_ENABLE` name in earlier docs, see
      docs/DECISIONS.md D4). New `ble_gatt.c`: one GATT service, STATS
      (read+notify) and CONFIG (read-only this phase) characteristics,
      UUIDs in docs/DATA_MODEL.md. `aggregate_run_hourly()`/
      `aggregate_run_daily_rollover()` extended with an optional
      out-record so a fresh aggregate triggers a STATS notify right after
      it's written to SD. PAIRING_STATUS and CONFIG-write deferred to
      Phase 5 (both need the bonding state machine to exist first, see
      docs/TASKS.md). Also corrected a second doc error: Phase 4's task
      list called for splitting WiFi/BLE across cores, impossible on the
      ESP32-C6's single HP core; replaced with an accurate description of
      software-arbitrated time-slicing on the one core.
      Verified on real hardware (nRF Connect for Mobile): connects
      without pairing (not-bonded, as designed), reads STATS
      (`{"date":"2026-07-08","hour":null,"unique":6,"returning":0,"kanon":true}`,
      leftover Phase 3 test data still on the SD card) and CONFIG
      (`{"rssi_floor":-85,"returning_window_days":30}`) return the exact
      expected JSON, CONFIG's ATT properties show read-only (no write
      exposed at the protocol level), and STATS notify-subscribe
      round-trips correctly in the log. Hit and fixed one real bug along
      the way: BLE advertisement data (flags + name + 128-bit UUID)
      exceeded the 31-byte legacy advertising limit, fixed by moving the
      device name into the scan response packet, see docs/LEARNINGS.md.
      Along the way, a deep investigation (BLE on/off A/B, raw
      promiscuous-callback counters, comparison against ESP-IDF's own
      sniffer example, a plain active WiFi scan finding 0 access points)
      traced a "zero WiFi packets captured" symptom to a loose antenna
      connection on the XIAO ESP32-C6, unrelated to BLE/coexistence and
      predating this refactor entirely (`wifi_sniffer.c` is
      byte-identical to `main`). User reseated the antenna; the same
      firmware immediately started capturing real ambient probes with
      BLE fully active (`active=1 obs=12 rssi=[-61,-52]`, growing
      `sd_bytes` on the card) - the first real (non-synthetic) WiFi
      capture confirmed end-to-end in this project, happening
      concurrently with BLE, i.e. direct evidence coexistence works.
      Followed up with a clean back-to-back packets/min comparison (two
      5-minute windows, same location): BLE on 23 observations/8 devices,
      BLE off 22 observations/6 devices - no measurable WiFi packet loss
      from BLE, satisfying docs/TASKS.md's Phase 4 acceptance criterion.
      See docs/LEARNINGS.md for the full investigation and resolution.
- [x] Phase 5: pairing (button + bonding) (2026-07-09). Short click on the
      tact switch (new `UI_EVENT_SHORT_CLICK` in `ui.c`, purely additive
      to the existing 3s long-press whitelist-arm gesture) opens a
      60-second pairing window (`UI_STATE_PAIRING`, cyan pulse). Physical-
      access gating (docs/DECISIONS.md D5) enforced at the link layer, not
      the SM layer: the controller's connection whitelist
      (`ble_gap_wl_set()`/`filter_policy`) only accepts connections from
      already-bonded peers normally (`BLE_HCI_ADV_FILT_CONN`), switching
      to accept-anyone (`BLE_HCI_ADV_FILT_NONE`) only during the open
      window - Just Works (`BLE_SM_IO_CAP_NO_IO`) has no app-level hook to
      refuse pairing itself, so the whitelist is what actually enforces
      "physical access required". New `runtime_config_parse.c`/`.h`
      (pure, host-tested) + `runtime_config.c`/`.h` (NVS-backed) make RSSI
      floor and returning-window days runtime-configurable; CONFIG's
      write is now implemented (`BLE_GATT_CHR_F_WRITE_ENC`, applies and
      persists via `runtime_config_apply_json()`).
      Verified on real hardware: pairing completes automatically on
      connection within the window (`encryption change; status=0` →
      `new bond established` → `whitelist refreshed: 1 bonded peer(s)`),
      and the bond survives a full device restart (`whitelist refreshed:
      1 bonded peer(s)` again after reboot). Hit and fixed three bugs
      along the way (`ble_store_config_init()` not exposed by any header,
      `CONFIG_BT_NIMBLE_NVS_PERSIST` needing a direct sdkconfig edit same
      as earlier phases, `BLE_GATT_CHR_F_WRITE_ENC` needing the base
      `_WRITE` flag alongside it), see docs/LEARNINGS.md.
- [x] Phase 6: mobile Flutter skeleton (2026-07-09). New write-only,
      bonded-only TIME_SYNC characteristic (`ble_gatt.c`, UUID in
      docs/DATA_MODEL.md) sets the device's wall clock
      (`sd_storage_set_wallclock_unix_s()`) from a raw little-endian
      uint32, matching docs/DECISIONS.md D6 ("phone sends unix time on
      every connection"). docs/DECISIONS.md D9 records `flutter_blue_plus`
      over `flutter_reactive_ble` as chosen in `.claude/rules/mobile-app.md`.
      Flutter wasn't installed on this machine; installed the SDK
      directly (see docs/LEARNINGS.md), then scaffolded `mobile/` via
      `flutter create` and wrote the full app: `lib/models/`
      (`Aggregate`/`DeviceConfig`, mirroring the STATS/CONFIG JSON in
      docs/DATA_MODEL.md), `lib/ble/ble_service.dart` (scan/connect,
      writes TIME_SYNC on every connect, subscribes + reads STATS,
      reads/writes CONFIG), `lib/storage/local_db.dart` (sqflite, one
      `aggregates` table, exactly the four aggregate fields, upsert keyed
      on date+hour), `lib/screens/` (pairing, dashboard with hourly/daily
      `fl_chart` bar charts + new/returning KPIs, settings for RSSI
      floor/returning window), full PL/EN l10n
      (`lib/l10n/app_en.arb`/`app_pl.arb`). `flutter analyze` and
      `flutter test` both pass clean.
      Verified end-to-end on a real Android phone (first-ever real phone
      run of this app): scans and finds the device, connects during the
      button-opened pairing window, TIME_SYNC write / STATS subscribe+read
      / CONFIG read all return `GATT_SUCCESS`, today's aggregate total
      lands in the local db and shows on the dashboard's KPI cards and
      daily chart, matching Phase 6's acceptance criteria (app pairs,
      syncs aggregates, shows data on a chart, no raw data in the local
      DB - the schema only has date/hour/counts by construction). Hit and
      fixed four real bugs getting there (Android 12+ BLE runtime
      permissions never requested, a stale Android GATT service cache
      hiding TIME_SYNC from a device the phone had met before this
      firmware added it, STATS subscribe never fetching what's already on
      the device before the next rollover, and SQLite silently not
      deduplicating `NULL`-keyed daily rows), see docs/LEARNINGS.md for
      all four.
      Known, deliberately out-of-scope gaps, not blocking this phase per
      docs/TASKS.md ("doesn't need a final design, needs to be
      functional"): no historical multi-day/hourly backfill on connect
      (only "today so far" syncs immediately, matching the acceptance
      criteria's plain "syncs aggregates"), the UI is functional but
      visually minimal, and a freshly-corrected device clock doesn't
      retroactively fix already-stale on-device aggregate files until the
      next real rollover (docs/DECISIONS.md D6 already frames this as
      expected drift-then-catch-up, not a bug).
- [ ] Phase 7: docs/compliance/README.md + README.md, final documentation
- [ ] Phase 8: production sync, multi-device, redesign (in progress,
      2026-07-10). Not in the original plan - added after real-phone use
      of Phase 6 surfaced concrete gaps: no way to get more than "today"
      onto the phone, had to manually re-scan every app launch even
      though already bonded, and the UI was bare Material widgets.
      Lives on `feature/sync-multidevice-redesign` (`refactor/ble-sd-flutter`
      is done, this branches off `main`). See docs/TASKS.md Phase 8 for
      the task breakdown.
      8a done: new write-only, bonded-only SYNC characteristic
      (`ble_gatt.c`, UUID/payload in docs/DATA_MODEL.md) replays
      unsynced `stats/daily.bin` records through the existing
      `ble_gatt_notify_stats()` - same STATS JSON, no new wire format.
      Paced off a dedicated 100ms timer (`sync_tick_cb()`, 8
      records/tick) instead of the original plan's housekeeper-tick
      idea, so a large backlog can't stall the NimBLE host task; this
      is a stricter version of the same "deferred, non-blocking, batched"
      design, not a scope change. Device holds no per-bond sync state,
      see docs/DECISIONS.md D10. Built clean, flashed, boot log confirms
      `registered characteristic 8f2c1e40-... def_handle=22 val_handle=23`
      with no errors and the rest of the system (SD, WiFi sniffer,
      whitelist) unaffected. The write path itself (an actual replay,
      triggered from a real BLE central) still needs a phone/nRF Connect
      test - not yet done, needs the user.
      8b-8e done (mobile, code complete, `flutter analyze`/`flutter test`
      clean after each): 8b added `shared_preferences`, light/dark
      `AppTheme`/`ThemeController`, and scoped `local_db.dart` by
      `device_id` (schema v3) with the artificial 30-row history cap
      removed. 8c added `BleService.tryAutoConnect()`
      (`FlutterBluePlus.systemDevices`, no scan) behind a new
      `ConnectingScreen` shown at launch, plus a device-switching section
      in Settings. 8d added `HomeShell` (bottom-nav
      Dashboard/Statystyki/Ustawienia, `IndexedStack`) replacing the old
      push-based navigation, `BleService.requestSync()` triggered
      automatically once per connection (cursor from
      `LocalDb.newestDailyDate()`) plus a manual "Synchronizuj teraz"
      button, and a new `statistics_screen.dart` (period totals/deltas,
      returning rate, day-of-week pattern, best-effort peak hour, all
      computed from aggregates already in the local db - no new
      per-client data). 8e added tap-for-detail tooltips on every bar
      chart (`fl_chart`'s built-in `BarTouchTooltipData`, not hand-rolled
      state), a light/dark/system theme picker in Settings, RSSI-floor/
      returning-window sliders replacing raw number fields, and a small
      dot-mark in the Dashboard app bar replacing an icon-in-a-box logo
      (explicitly rejected during design review as looking generated
      rather than like a real product mark).
      8f (unplanned, added after 8e per direct user feedback on real
      hardware): real glass-morphism (`BackdropFilter`/`GlassCard`,
      `GradientBackground`), tap-to-detail `showModalBottomSheet` on every
      bar chart replacing the old tooltip-only interaction (with a
      computed interpretation line - peak hour/best day/vs-period-average),
      a `SyncStatusBanner` on the dashboard showing live paired/connected
      + syncing/last-synced state (`BleService.isSyncing`/
      `lastSyncCompleted`, a 1500ms idle timer matching the wire
      protocol's own "quiet period = done" design), and a shared
      "Revolut style" bar chart look (`chart_style.dart`: rounded
      gradient bars, no grid/axis chrome, exact values moved into the
      tap-detail sheet). Also fixed a real bug found on hardware during
      this pass: `tryAutoConnect()` picking the wrong bonded BLE device
      (see docs/LEARNINGS.md 2026-07-10) - now tries every
      `systemDevices()` candidate before falling back to a real
      service-UUID-filtered scan.
      Hardware pass (2026-07-10): confirmed end-to-end on a real phone -
      auto-reconnect now connects straight to the correct device with
      zero manual intervention, TIME_SYNC/STATS/CONFIG/SYNC all succeed,
      sync status banner and Revolut-style charts render correctly on
      both Dashboard and Statystyki, tap-to-detail sheets open with
      correct data and interpretation text.
      Still open: the hourly chart ("Odwiedziny godzinowe") shows "no
      synced data" on a fresh connect - SYNC only replays
      `stats/daily.bin`, never today's hourly breakdown, so hourly bars
      only fill in from live hour-boundary notifications during the
      current connection. Needs a firmware-side decision (extend SYNC, or
      a separate mechanism, to also backfill today's hourly file) before
      this phase can be marked fully done - not yet asked/actioned.

Note: the current code in `firmware/` and `app/` is still the old
architecture (USB-CDC → Python desktop dashboard, SQLite). Don't remove /
change it until the new path (BLE+SD) is ready and tested in parallel.

Last updated: 2026-07-10 (Phase 8a-8f verified on real hardware; hourly
backfill on connect still open, see Phase 8 notes above).
