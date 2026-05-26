# PrintBack

Retail footfall analytics that runs entirely on the operator's own hardware.
A tiny ESP32-C6 sniffs WiFi probe requests near the entrance, hashes them
into pseudonymous device fingerprints on the chip, and streams one JSON line
per observation over USB to a desktop dashboard that shows live traffic,
returning vs. new visitor split, and frequency segmentation.

No cloud, no network calls, no third-party services. One SQLite file on the
operator's PC.

![dashboard](docs/dashboard.png)

## What it does

- **Counts unique devices** with a rolling active-now window plus daily totals.
- **Splits new vs. returning visitors** using a 30-day lookback over stable
  IE-based fingerprints (configurable).
- **Auto-whitelists sustained presence** — staff phones, the router, the
  neighbouring shop's WiFi — using a hours-per-window heuristic. Operator
  can override false positives.
- **Layered retention** with automatic purge: 30 days raw observations,
  365 days daily aggregates (no MAC, no per-event RSSI), unlimited
  identifier-free totals.
- **Daily SQLite backup** (atomic `VACUUM INTO`, 7-day rotation).
- **Bilingual UI** — Polish / English, toggle in Settings → Language.

## Repository layout

- `firmware/` — ESP-IDF C firmware for the XIAO ESP32-C6 board. Promiscuous
  WiFi sniffer, IE hashing on-chip (host never sees raw bytes), tact-switch
  plus RGB LED for whitelist capture, Task / Interrupt / Brownout watchdogs
  for unattended stability.
- `app/` — Python desktop app (PySide6 + pyqtgraph + stdlib sqlite3 +
  pyserial). Live and historical dashboard, hourly chart, 7-day comparison,
  visit-frequency segmentation. Includes a supervisor wrapper and software
  USB reset (Windows `pnputil`) for unattended deployment.
- `docs/compliance/` — plain-language technical brief describing the data
  architecture, retention design, and the privacy choices that are
  architecturally enforced (no crosslinking, no network calls, no raw
  export). Intended as a starting point for a lawyer drafting downstream
  RODO / GDPR documents per deployment.

## Quick start

### Firmware

Requires ESP-IDF 5.3+ and a XIAO ESP32-C6.

```sh
cd firmware
idf.py set-target esp32c6
idf.py build
idf.py -p <COMx> flash monitor
```

The device emits one JSON line per probe over USB-CDC at 115200 baud:

```json
{"t":12345678,"fp":"cba68c5d230c5649","mac":"a4c1380c2e3f","rssi":-67,"ch":6,"ies":11,"new":true,"wl":false}
```

### App

Requires Python 3.11+.

```sh
cd app
python -m venv .venv
.venv\Scripts\activate                  # Windows
pip install -e .
printback                               # auto-detects ESP via VID; --port COMx to override
```

For unattended deployment use `app/scripts/run-as-admin.bat` — wraps the app
in a supervisor that restarts it on crashes and can issue a software USB
reset when the Windows driver gets stuck without unplugging the cable.

Data and config live under `%APPDATA%\PrintBack\` on Windows
(`~/.local/share/PrintBack/` on Linux).

## Honest limits

WiFi probe sniffing is a useful proxy for footfall but not a precise
measurement. Modern phones randomize their MAC and some randomize WiFi
capabilities between probe bursts, so the same real visitor can appear as
2-3 different fingerprints. Treat the numbers as trend estimation with a
~10-30% error margin — "traffic up 15% this week", not "exactly 142
customers".

## License

PolyForm Noncommercial 1.0.0 — see [LICENSE](LICENSE). Free for personal,
research and educational use. Commercial use requires a separate license.
