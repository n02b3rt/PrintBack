# PrintBack: what we do with the data

Plain-language description of the data architecture. Purpose: anyone (you, a
lawyer, a partner, a hypothetical auditor) gets a clear 5-minute picture of what
the system collects, where it stores it, what it uses it for, and what it
deliberately doesn't do. No "everything is fine" salesmanship: WiFi sniffing
and probe-tracking sits on a regulatory edge by nature. This file is descriptive,
the lawyer takes it and drafts whatever downstream documents are needed.

Every claim below is a property of the code as it stands, not an intention.
Where a number or a rule is enforced somewhere specific, the file is named so
it can be checked rather than believed.

## The shape of the system

Two pieces, one radio link, no third one:

- an **ESP32-C6** near the entrance, with an SD card. It listens, hashes,
  aggregates, and stores. It has no internet connection of any kind.
- a **phone app** (Flutter, Android). It pairs with the device over Bluetooth
  and pulls **counts**. It has no `INTERNET` permission in the release build.

There is no server, no cloud, no account, and no third party. The two devices
talk to each other and to nobody else.

## What we collect

The ESP32 listens to WiFi probe requests: broadcast frames every phone with WiFi
enabled emits every few tens of seconds looking for known networks. From each
frame the device derives:

- **fingerprint**: an 8-byte salted hash of the Information Elements (IEs) in
  the frame. Stable across observations of the same device configuration, **not
  a MAC**, and it does not identify a person. Computed on the ESP32 itself; the
  raw IE bytes never leave the chip.
- **RSSI**: signal strength in dBm. A rough proxy for distance, used to ignore
  passers-by (see the range setting below).
- **channel** (1 / 6 / 11): purely diagnostic.
- **timestamp**.

**The MAC address is not stored.** The frame's source MAC is read into a struct
field in RAM (`probe_observation_t.src_mac`, `firmware/main/wifi_sniffer.h`) and
then simply never used: it is not written to the SD card, not emitted, and not
sent over Bluetooth. The on-disk record is `sd_raw_record_t`
(`firmware/main/sd_paths.h`) - timestamp, fingerprint, RSSI, channel, flags -
and there is no field for it to go in.

We don't read SSID names, we don't look at frame payload, and we don't touch
any frames outside the management/probe-request subtype.

### The fingerprint salt

On first boot each device generates 16 random bytes (`esp_fill_random`), keeps
them in NVS, and hashes them into every fingerprint before anything else
(`firmware/main/fingerprint.c`). Two consequences worth stating plainly:

- the same phone produces a **different** fingerprint on every PrintBack unit,
  so two operators' data cannot be correlated even if someone got hold of both;
- the fingerprint is meaningless outside the device that made it. It is not a
  lookup key into anything, here or anywhere else.

Wiping the device's NVS regenerates the salt, which permanently severs the link
to all previous fingerprints - i.e. it resets returning-visitor history.

## Why we collect it

Business goal: **footfall statistics and returning-customer analytics** for the
operator's premises. Concrete questions we want to answer:

- how many unique devices today, yesterday, this week
- what fraction are returning (seen before) vs new
- hourly traffic distribution (when's the peak)
- trend over time (is footfall growing or shrinking)

What is **not** the goal: tracking a specific individual, matching to
transactions, sending notifications, integrating with CCTV. This architecture
literally can't do those things, see "What the system doesn't do" below.

This is a well-established category of tool. Spaceti, FootfallCam, Brickstream
and similar vendors run essentially the same approach at scale in Polish
shopping galleries. It's not novel territory.

## How the data is stored

Everything lives on the **device's own SD card**. Two tiers, and the line
between them is the line between pseudonymous and anonymous:

**Raw observations - 30 days, on the device only**
`/sdcard/logs/raw/YYYYMMDD.bin`, one fixed 16-byte record per probe:
timestamp, fingerprint, RSSI, channel, flags. This is the only pseudonymous
tier. A rolling purge deletes any file older than the retention window
(`sd_storage_purge_old()`, `firmware/main/sd_storage.c`), which is a
compile-time constant (`CONFIG_PRINTBACK_SD_RETENTION_DAYS`, default 30), not
something the operator can quietly extend from the app.

**Aggregates - kept indefinitely, on the device and on the phone**
`/sdcard/logs/stats/`, one 12-byte record per hour or per day: date, hour,
unique count, returning count, k-anonymity flag (`aggregate_record_t`,
`firmware/main/sd_paths.h`). **No fingerprint, no identifier of any kind** -
these are counts. That's why they're kept forever: year-over-year trend costs
nothing in privacy terms, because there is nobody in the data to protect.

The purge deliberately touches only the raw directory. Aggregates are not
personal data and are not purged.

**On the phone**: one table, five columns - device id plus the four aggregate
fields (`mobile/lib/storage/local_db.dart`). The phone has never seen a
fingerprint and has nowhere to put one.

## What leaves the device

Only over Bluetooth, only to a phone that was physically paired at the device
(see below), and only these:

| Characteristic | Carries |
|---|---|
| STATS | one aggregate: date, hour, unique count, returning count, k-anon flag |
| SYNC | asks the device to replay past aggregates; the replies are STATS records |
| CONFIG | the two runtime settings (range floor, returning window) |
| TIME\_SYNC | the phone's clock, written to the device |
| STATUS | device health: firmware version, uptime, free space, heap, whitelist **size** |

Wire format and UUIDs: [../DATA_MODEL.md](../DATA_MODEL.md). Note what is
absent: there is no characteristic that carries a fingerprint, because no such
data structure exists on the phone's side of the link.

### k-anonymity

An hour with fewer than 5 unique devices is **never published** - not to the
phone, not into the hourly stats file (`kanon_hourly_publishable()`,
`firmware/main/kanon.c`). It still counts toward the day's total. The reason is
that a count of 1 or 2 in a quiet hour starts to be about a person rather than
about traffic ("at 7am it was only the postman").

The app shows those hours as "<5" rather than as zero, so the floor is visible
rather than mistaken for an absence of visitors.

### Pairing requires physical access

A phone cannot connect on its own. The device only accepts connections from
already-bonded peers (a link-layer connection whitelist), and the window for a
*new* bond only opens when someone presses the button on the device
(`firmware/main/ble_gatt.c`, and [../DECISIONS.md](../DECISIONS.md) D5). Up to
**three** phones can be bonded at once (`CONFIG_BT_NIMBLE_MAX_BONDS`); a fourth
displaces the oldest.

## Auto-whitelist

The system spots "obviously-not-a-customer" devices: if a fingerprint appears
in 6+ distinct hours within an 8-hour rolling window **and** has been observed
at least 30 times (i.e. something is sitting on premises for most of a shift
and actually generating traffic, not just glimpsed once an hour), it's
auto-added to the whitelist and stops counting toward statistics. Both
thresholds are enforced in firmware (`wl_auto.c`) and are Kconfig values, not
runtime settings.

The operator can also add a phone by hand: hold the button for 3 seconds and
hold the phone against the device within 30 seconds (a very high RSSI is
required, so a customer standing nearby can't be caught by accident).

The app shows **how many** devices are on that list and never which - it's a
count on the STATUS characteristic, and there is no wire format that could
carry more. This is data minimisation: we don't process the data of devices
that obviously aren't part of the use case.

## Diagnostic reports ("shake to report a problem")

Shaking the phone three times opens a bug-report sheet in the mobile app. It
is deliberately built so that no personal data of a data subject can be in
play:

- **No visitor data can be included, by construction.** The phone only ever
  receives aggregate counts, never a per-client identifier (see D3 in
  [../DECISIONS.md](../DECISIONS.md)) - so there is simply no visitor data on
  the device for a report to pick up. What a report carries is the *operator's
  own* technical data about their own device: app version, OS, connection/sync
  state, cached row counts, and the device's own STATUS.
- **Consent is explicit and informed.** The gesture only *opens* the sheet.
  Nothing is submitted until the operator taps "send", and the sheet shows a
  verbatim preview of the exact outgoing text first. Technical logs can be
  switched off entirely and the report still sends.
- **Logs are ephemeral and scrubbed.** They live in a capped in-memory ring
  buffer (`mobile/lib/services/log_buffer.dart`), are never written to disk,
  and vanish when the app closes. Anything shaped like a Bluetooth/MAC address
  is masked on the way in (unit-tested in
  `mobile/test/log_buffer_test.dart`), so a hardware address can't ride along
  even by accident.
- **We transmit nothing.** There is no backend and the app makes no outbound
  calls of its own; submitting hands the text to the OS share sheet and the
  operator chooses the channel. `BugReportSink`
  (`mobile/lib/services/bug_report.dart`) is the seam where a real support
  backend would later plug in - **at which point this section and the consent
  copy must be revisited**, because that would introduce a processor and a
  transmission where today there is neither.

## What the system doesn't do (architecture-enforced)

These constraints are baked into the code, not just declared:

- **The device has no network.** No WiFi client mode, no AP, no internet
  connection. It sniffs and it talks Bluetooth to one paired phone. There is
  nowhere for data to go.
- **No network permission on the phone, and no cloud backup.** The Android
  release manifest declares no `INTERNET` permission at all - verified on the
  *merged* release manifest, not just the source one, so it stays true with the
  BLE/notification/share plugins merged in. "Nothing leaves the phone" is a
  property of the build rather than a promise. The app also opts out of Android
  Auto Backup and device-to-device transfer (`allowBackup="false"` +
  `res/xml/data_extraction_rules.xml`), which would otherwise have copied the
  cached counts to the operator's Google Drive.
- **No MAC is ever stored.** See "What we collect" - the on-disk record has no
  field for it.
- **Hash computed on the ESP32.** Raw IE bytes never leave the chip. Everything
  downstream sees a salted pseudonym, not the source material.
- **No crosslinking.** The phone's schema has no columns or interfaces to join
  anything with anything external (CRM, loyalty, POS, CCTV), and the only
  identifier it holds is which of the operator's own devices a row came from.
- **No raw export.** The .xlsx export carries exactly the columns the phone
  holds - dates, hours, counts. There is deliberately no path from the app to
  the device's raw records; adding one would turn an anonymous export into a
  pseudonymous one and change this entire analysis.
- **Auto-purge.** Raw retention isn't "up to the operator": it's a firmware
  constant and a rolling purge on the device.

## Honest precision limits

- iOS 14+ and Android 10+ randomize the MAC in probe requests every few minutes.
  The IE-fingerprint is more stable, but some phones randomize aggressively
  enough that the same returning customer can look like 2-3 different devices.
  **The "% returning" number underestimates by something like 10-30%.**
- The sniffer picks up signal within a radius; in a shopping passage it can
  count people from the shop next door. The RSSI floor (default -85 dBm) filters
  most of that out, but not perfectly.
- The device has no battery-backed clock. After a power cut it can misdate
  records until a phone connects and sets the clock
  ([../DECISIONS.md](../DECISIONS.md) D6).
- This is **trend estimation**, not precise measurement. Present it to the boss
  / partner as "traffic up ~15%", never "exactly 142 customers walked in". The
  app says this in its own words too, in the FAQ and on every export.

## Configuration

Two layers, deliberately:

**Build-time (Kconfig, `firmware/main/Kconfig.projbuild`)** - the values that
carry the privacy argument. Changing them means rebuilding and reflashing the
firmware, which is not something that happens by accident or from a phone:

| Setting | Default | What it governs |
|---|---|---|
| `PRINTBACK_SD_RETENTION_DAYS` | 30 | how long raw observations survive |
| `PRINTBACK_AUTO_WL_WINDOW_HOURS` | 8 | auto-whitelist rolling window |
| `PRINTBACK_AUTO_WL_MIN_DISTINCT_HOURS` | 6 | hours needed to qualify |
| `PRINTBACK_AUTO_WL_MIN_OBSERVATIONS` | 30 | observations needed to qualify |
| `PRINTBACK_PAIRING_WINDOW_SECONDS` | 60 | how long the button opens pairing |

The k-anonymity threshold lives in `firmware/main/kanon.h`
(`KANON_MIN_HOURLY_COUNT`, 5) - deliberately a constant rather than a Kconfig
option, so it isn't presented as a knob to turn.

**Runtime (BLE CONFIG, from the app)** - only the two settings that are about
tuning the measurement to a room, not about what is retained:

```json
{ "rssi_floor": -85, "returning_window_days": 30 }
```

Defaults are intended as ceilings. Shortening retention is always safe.
Extending it beyond 30 days is a deliberate decision that changes the argument
in this document and should be documented in that operator's own DPIA.
