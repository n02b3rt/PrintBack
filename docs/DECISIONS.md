# Architectural decisions (ADR-lite): PrintBack refactor (BLE + SD + Flutter)

A short log of "why we did it this way and not another", so a fresh
session doesn't try to "improve" the architecture into something that
looks nicer without knowing we already considered and rejected it.

## D1: BLE instead of WiFi AP + PWA for data sync

Rejected: C6 as a WiFi AP + HTTP server serving a PWA.

Reason: WiFi monitor mode (sniffing) and AP mode can't run at the same
time on the same radio without switching modes and losing packets. BLE
coexists with monitor mode much better (separate software coex, no WiFi
mode switching needed).

## D2: Flutter instead of PWA for the mobile app

Rejected: PWA with Web Bluetooth.

Reason: Web Bluetooth doesn't work in Safari/iOS at all, no workaround.
Flutter gives one codebase for Android+iOS with native BLE.

## D3: Aggregates on the phone, raw data only on the device's SD

Reason: GDPR. Aggregated counts (with no per-client identifier) aren't
personal data, so they can be kept without a retention limit. Raw data
(even a hashed MAC) is still personal data under GDPR, hence the hard
30-day limit and the fact that it NEVER leaves the device.

## D4: C6 (not H2/C6-Thread) for WiFi+BLE

Reason: one 2.4GHz radio shared in software (CONFIG_SW_COEXIST_ENABLE)
works well for WiFi+BLE (a mature, common use case, e.g. BLE
provisioning). WiFi+Thread on the same radio has much worse coexistence,
confirmed by earlier tests on another project, see docs/LEARNINGS.md.

## D5: Pairing, physical button + BLE bonding

Rejected: Just Works with no physical interaction (vulnerable to a
remote MITM on first pairing).

Chosen: a button on the device starts pairing mode for time X, then
bonding in NVS, requires physical access to the device the first time.

## D6: Phone as the wall-clock time source

Rejected: a hardware RTC (e.g. DS3231 on I2C), a new BOM component, new
wiring, never planned anywhere in the project before.

Rejected: time purely relative to boot, with no calendar dates, deviates
from the file naming in docs/TASKS.md (`YYYY-MM-DD.bin`) and makes
reading dates directly harder.

Chosen: the phone sends the current unix time on every BLE connection.
Reason: the device has no RTC or WiFi-STA/NTP (deliberately, the "no
network calls" rule), and the phone already has to be physically present
for pairing and every sync (D5), zero new hardware. The device keeps
`esp_timer_get_time()` as a monotonic source + an offset corrected on
every sync; drift is only possible if the phone doesn't connect for a
long time.

## D7: JSON instead of CBOR for BLE STATS

Rejected: CBOR.

Reason: the payload is small anyway (<100B/record), so CBOR's ~30-50%
savings don't matter at this scale. JSON renders readably in a generic
BLE scanner (nRF Connect) used for verification in Phase 4
(docs/TASKS.md), CBOR would need a separate decoder, which makes
verifying the hardware solo harder. JSON needs no new on-device
dependency (and the coexistence build, NimBLE + WiFi + SD + FAT, is
already complex enough), Flutter has `dart:convert` built in.
