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
- [ ] Phase 6: mobile Flutter skeleton
- [ ] Phase 7: docs/compliance/README.md + README.md, final documentation

Note: the current code in `firmware/` and `app/` is still the old
architecture (USB-CDC → Python desktop dashboard, SQLite). Don't remove /
change it until the new path (BLE+SD) is ready and tested in parallel.

Last updated: 2026-07-09 (Phase 5).
