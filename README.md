# PrintBack

Retail footfall analytics that runs entirely on the operator's own hardware.
A tiny ESP32-C6 sniffs WiFi probe requests near the entrance and hashes them
into pseudonymous device fingerprints on the chip. Raw observations stay on
its own SD card for 30 days; hourly and daily counts get computed on-device.
Only those counts are served over BLE to a companion Flutter app, showing
live traffic, returning vs. new visitor split, and trends over time.

No MAC address is ever stored, anywhere - not on the SD card, not in debug
output. The salted fingerprint that replaces it never leaves the device
either. See [docs/compliance/README.md](docs/compliance/README.md) for what
that means in practice and why it was built that way.

No cloud, no server, no third-party services.

![dashboard](docs/dashboard.png)

*The app's dashboard and statistics, in Polish. Numbers are from the
built-in demo mode, not a real deployment.*

## What it does

- Counts unique devices with a rolling active-now window plus daily totals.
- Splits new vs. returning visitors using a lookback over stable IE-based
  fingerprints (window configurable from the app, no reflash).
- Whitelists sustained presence (staff phones, the router, the neighbouring
  shop's WiFi) two ways: a physical button on the device (hold to capture),
  and automatically - a fingerprint seen in 6+ distinct hours within a
  rolling 8h window *and* observed 30+ times drops out of the counts.
- Layered retention with automatic purge: 30 days of raw observations on
  the SD card, unlimited retention for aggregates since they carry no
  identifiers ([docs/DECISIONS.md](docs/DECISIONS.md) D3).
- k-anonymity enforced on-device: hourly aggregates below a 5-event
  threshold get folded into the daily total instead of published hourly.

## Repository layout

- `firmware/`: ESP-IDF C firmware for the XIAO ESP32-C6. Promiscuous WiFi
  sniffer, IE hashing on-chip, SD storage with rolling purge, hourly/daily
  aggregation behind the k-anonymity gate, and a NimBLE GATT server serving
  aggregates to bonded phones only. Tact switch plus RGB LED for pairing,
  whitelist capture and recovery gestures; task/interrupt/brownout watchdogs
  for unattended stability. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `mobile/`: Flutter companion app (Android + iOS), BLE central. Caches
  aggregates only, works offline from that cache, and is bilingual (PL/EN).
  Dashboard, statistics with drill-down charts, xlsx export, shareable
  report card.
- `docs/compliance/`: plain-language description of the data architecture,
  retention design and privacy choices actually enforced in the code.
  Starting point for a lawyer drafting RODO/GDPR paperwork per deployment.

## Quick start

### Firmware

Requires ESP-IDF 5.3+ and a XIAO ESP32-C6 with an SD card wired over SPI.

```sh
cd firmware
idf.py set-target esp32c6
idf.py build
idf.py -p <COMx> flash monitor
```

The device's output is an aggregate served over BLE (see
[docs/DATA_MODEL.md](docs/DATA_MODEL.md)), not a per-probe line:

```json
{"date":"2026-07-02","hour":14,"unique":37,"returning":22,"kanon":false}
```

A per-probe USB-CDC debug line still exists for bench debugging (115200
baud). Note what isn't in it - there is no MAC field, because the MAC is
never stored in the first place:

```json
{"t":12345678,"fp":"cba68c5d230c5649","rssi":-67,"ch":6,"ies":11,"new":true,"wl":false}
```

### Mobile app

Requires Flutter 3.x.

```sh
cd mobile
flutter pub get
flutter run
```

Pairing needs physical access to the device: press its button to open a
short pairing window, then pair from the app. Up to 3 phones can stay
bonded. Without the button, a stranger in BLE range gets nothing.

## Honest limits

WiFi probe sniffing is a useful proxy for footfall, not a precise
measurement. Modern phones randomize their MAC and some randomize WiFi
capabilities between probe bursts, so the same visitor can show up as 2-3
different fingerprints. Treat the numbers as trend estimation with a
~10-30% error margin: "traffic up 15% this week", not "exactly 142
customers".

The same randomization is what makes the returning-visitor split an
estimate rather than a count: it only sees devices whose fingerprint stays
stable between visits.

## License

PolyForm Noncommercial 1.0.0, see [LICENSE](LICENSE). Free for personal,
research and educational use. Commercial use requires a separate license.
