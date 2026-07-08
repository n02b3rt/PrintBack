# Progress: PrintBack refactor (BLE + SD + Flutter)

- [x] Phase 0: starting documentation (project rules index, docs/DECISIONS.md,
      docs/LEARNINGS.md, docs/PROGRESS.md, docs/TASKS.md,
      docs/ARCHITECTURE.md/docs/DATA_MODEL.md skeletons, local rules notes) (2026-07-02)
- [x] Phase 0.5: tooling (`refactor/ble-sd-flutter` branch, dev_cycle.py,
      pre-commit MAC-leak guard, host test harness + kanon.c example) (2026-07-02)
- [x] Phase 1: docs/ARCHITECTURE.md, docs/DATA_MODEL.md, README.md,
      docs/DECISIONS.md D6/D7, see docs/TASKS.md (2026-07-04)
- [ ] Phase 2: SD card logging, in progress (2026-07-08). Done: SPI SD
      card mount (`sd_storage.c`), raw record write path, path/purge
      logic + host tests (`sd_paths.c`), Kconfig pins/retention/wallclock
      fallback, wired into `on_probe()`. Verified: host tests green,
      `idf.py build` clean, real hardware boot confirms
      `SD ready: MSSD0, 59700MB` mount success, stable heap across
      housekeeper ticks. NOT yet verified on hardware: an actual raw
      `.bin` file landing (no probe traffic during the test session to
      trigger a write) and the 30-day purge sweep (needs either real
      elapsed time or the shortened-window test TASKS.md suggests).
      See docs/LEARNINGS.md for issues hit along the way.
- [ ] Phase 3: on-device aggregation, drop raw MAC
- [ ] Phase 4: BLE GATT server
- [ ] Phase 5: pairing button + bonding
- [ ] Phase 6: mobile Flutter skeleton
- [ ] Phase 7: docs/compliance/README.md + README.md, final documentation

Note: the current code in `firmware/` and `app/` is still the old
architecture (USB-CDC → Python desktop dashboard, SQLite). Don't remove /
change it until the new path (BLE+SD) is ready and tested in parallel.

Last updated: 2026-07-02.
