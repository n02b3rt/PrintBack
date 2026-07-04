# Progress — refaktor PrintBack (BLE + SD + Flutter)

- [x] Faza 0: dokumentacja startowa (docs/DECISIONS.md,
      docs/LEARNINGS.md, docs/PROGRESS.md, docs/TASKS.md, szkielety
      docs/ARCHITECTURE.md/docs/DATA_MODEL.md) — 2026-07-02
- [x] Faza 0.5: narzędzia (gałąź `refactor/ble-sd-flutter`, dev_cycle.py,
      pre-commit MAC-leak guard, host test harness + przykład kanon.c) — 2026-07-02
- [x] Faza 1: docs/ARCHITECTURE.md, docs/DATA_MODEL.md, README.md,
      docs/DECISIONS.md D6/D7 — patrz docs/TASKS.md — 2026-07-04
- [ ] Faza 2: SD card logging
- [ ] Faza 3: agregacja on-device, drop raw MAC
- [ ] Faza 4: BLE GATT server
- [ ] Faza 5: pairing button + bonding
- [ ] Faza 6: mobile Flutter skeleton
- [ ] Faza 7: docs/compliance/README.md + README.md — dokumentacja końcowa

Uwaga: obecny kod w `firmware/` i `app/` to wciąż stara architektura
(USB-CDC → Python desktop dashboard, SQLite). Nie usuwać / nie zmieniać, dopóki
nowa ścieżka (BLE+SD) nie jest gotowa i przetestowana równolegle.

Ostatnia aktualizacja: 2026-07-02.
