# PrintBack

> **Status:** this README describes the target architecture on
> `refactor/ble-sd-flutter` (BLE + SD + Flutter). `main` is today's shipped
> system (USB-CDC → desktop dashboard), described below where still
> accurate. See [docs/PROGRESS.md](docs/PROGRESS.md) for what's actually
> built on this branch, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) /
> [docs/DATA_MODEL.md](docs/DATA_MODEL.md) for detail.

Retail footfall analytics that runs entirely on the operator's own hardware.
A tiny ESP32-C6 sniffs WiFi probe requests near the entrance and hashes them
into pseudonymous device fingerprints on the chip. Raw observations stay on
its own SD card for 30 days; hourly and daily counts get computed on-device.
Only those counts are served over BLE to a companion Flutter app, showing
live traffic, returning vs. new visitor split, and frequency segmentation.
No raw fingerprint and no MAC address ever leave the device.

No cloud, no server, no third-party services.

![dashboard](docs/dashboard.png)

## What it does

- Counts unique devices with a rolling active-now window plus daily totals.
- Splits new vs. returning visitors using a lookback over stable IE-based
  fingerprints (configurable). Exact returning-window definition:
  [docs/DATA_MODEL.md](docs/DATA_MODEL.md), "Otwarte pytania".
- Whitelists sustained presence (staff phones, the router, the neighbouring
  shop's WiFi) via a physical button on the device: hold to capture. No
  automatic hours-per-window detection yet.
- Layered retention with automatic purge: 30 days of raw observations on
  the SD card, unlimited retention for aggregates since they carry no
  identifiers ([docs/DECISIONS.md](docs/DECISIONS.md) D3).
- k-anonymity enforced on-device: hourly aggregates below a 5-event
  threshold get folded into the daily total instead of published hourly.

## Repository layout

- `firmware/`: ESP-IDF C firmware for the XIAO ESP32-C6. Promiscuous WiFi
  sniffer, IE hashing on-chip (host never sees raw bytes), tact-switch plus
  RGB LED for whitelist capture, task/interrupt/brownout watchdogs for
  unattended stability. Target architecture adds SD storage, hourly/daily
  aggregation and a BLE GATT server, see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `app/`: Python desktop app (PySide6 + pyqtgraph + stdlib sqlite3 +
  pyserial). Live and historical dashboard, hourly chart, 7-day comparison,
  visit-frequency segmentation. Includes a supervisor wrapper and software
  USB reset (Windows `pnputil`) for unattended deployment. Gets phased out
  once the BLE/mobile path is complete.
- `mobile/`: Flutter companion app (Android + iOS), BLE central, caches
  aggregates only. Not built yet, Phase 6, see [docs/TASKS.md](docs/TASKS.md).
- `docs/compliance/`: plain-language description of the data architecture,
  retention design and privacy choices enforced in the code. Starting point
  for a lawyer drafting RODO/GDPR paperwork per deployment. Describes
  today's USB/desktop system, update scheduled for Phase 7.

## Quick start

### Firmware

Requires ESP-IDF 5.3+ and a XIAO ESP32-C6.

```sh
cd firmware
idf.py set-target esp32c6
idf.py build
idf.py -p <COMx> flash monitor
```

Target architecture: the device's headline output is an aggregate served
over BLE (see [docs/DATA_MODEL.md](docs/DATA_MODEL.md)), not a per-probe
line:

```json
{"date":"2026-07-02","hour":14,"unique":37,"returning":22,"kanon":false}
```

A per-probe USB-CDC debug line still exists today for bench debugging
(115200 baud). No MAC field: raw MAC never appears outside the device's
own SD card, not even in USB debug output:

```json
{"t":12345678,"fp":"cba68c5d230c5649","rssi":-67,"ch":6,"ies":11,"new":true,"wl":false}
```

### App (current, main branch)

Requires Python 3.11+.

```sh
cd app
python -m venv .venv
.venv\Scripts\activate                  # Windows
pip install -e .
printback                               # auto-detects ESP via VID; --port COMx to override
```

For unattended deployment use `app/scripts/run-as-admin.bat`: wraps the app
in a supervisor that restarts it on crashes and can issue a software USB
reset when the Windows driver gets stuck without unplugging the cable.

Data and config live under `%APPDATA%\PrintBack\` on Windows
(`~/.local/share/PrintBack/` on Linux).

### Mobile app (target, this branch)

Not built yet, Phase 6, see [docs/TASKS.md](docs/TASKS.md). Will live in
`mobile/`, Flutter (`flutter_blue_plus`), pairs with the device over BLE and
caches aggregates only.

## Honest limits

WiFi probe sniffing is a useful proxy for footfall, not a precise
measurement. Modern phones randomize their MAC and some randomize WiFi
capabilities between probe bursts, so the same visitor can show up as 2-3
different fingerprints. Treat the numbers as trend estimation with a
~10-30% error margin: "traffic up 15% this week", not "exactly 142
customers".

## License

PolyForm Noncommercial 1.0.0, see [LICENSE](LICENSE). Free for personal,
research and educational use. Commercial use requires a separate license.
