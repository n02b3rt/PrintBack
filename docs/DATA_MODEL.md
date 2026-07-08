# Data model: PrintBack (BLE + SD)

Formats for the target architecture (`refactor/ble-sd-flutter`), context:
[docs/ARCHITECTURE.md](ARCHITECTURE.md). Little-endian everywhere (RISC-V HP
core on the C6), matters for any future tool (Flutter, desktop) that ever
reads raw `.bin` files directly.

## Raw record on SD

```c
/* firmware/main/sd_storage.h, Phase 2 */
typedef struct __attribute__((packed)) {
    uint32_t timestamp_unix_s;            /* UTC unix seconds. The device has
                                            * no RTC, see ARCHITECTURE.md
                                            * "Wall-clock time" (the phone
                                            * sends the time on connect). */
    uint8_t  fp[FINGERPRINT_HASH_BYTES];  /* 8-byte IE hash. NEVER a raw MAC,
                                            * not even on SD, not just over
                                            * BLE. */
    int8_t   rssi;                        /* dBm, same as in probe_observation_t */
    uint8_t  channel;                     /* 1/6/11 today */
    uint8_t  flags;                       /* bit0 is_new (fresh within the
                                            * tracker's 5-minute RAM window,
                                            * same semantics as today's
                                            * "new" JSON field)
                                            * bit1 is_returning (see
                                            * "Open questions" below)
                                            * bit2 is_whitelisted
                                            * bit3-7 reserved, write 0 */
    uint8_t  _reserved;                   /* padding to 16B, write 0 */
} sd_raw_record_t;                        /* 16 bytes, one record = one probe */
```

File: `/sdcard/logs/raw/YYYYMMDD.bin`, append-only, fixed-length
records, record N sits at offset N×16, trivial seek/truncate for the
30-day purge. No dashes in the date: FAT short (8.3) filenames don't fit
`YYYY-MM-DD` without enabling Long File Name support, learned the hard
way on real hardware, see docs/LEARNINGS.md.

## Aggregate record

```c
typedef struct __attribute__((packed)) {
    uint32_t date_unix_day;        /* days since 1970-01-01 UTC (unix_seconds_
                                     * at_midnight / 86400). An integer,
                                     * not separate year/month/day fields,
                                     * keeps the struct a fixed size, zero
                                     * calendar math on-device; conversion
                                     * to a date string happens app-side
                                     * or when serializing to JSON. */
    int8_t   hour_or_day;          /* 0-23 = hourly bucket; -1 = whole
                                     * day */
    uint16_t unique_count;         /* unique, non-whitelisted fp in the window */
    uint16_t returning_count;      /* subset of unique_count seen on an
                                     * earlier day within the returning window,
                                     * same open question as below */
    uint8_t  k_anonymity_applied;  /* bool. Hourly records: always 0,
                                     * the record only exists if
                                     * kanon_hourly_publishable() (firmware/
                                     * main/kanon.c) already returned true.
                                     * Daily records: 1 if >=1 hour of
                                     * that day got folded into the
                                     * daily total because it didn't pass
                                     * the threshold on its own. */
    uint8_t  _reserved[2];         /* padding to 12B, write 0 */
} aggregate_record_t;              /* 12 bytes */
```

Files: `/sdcard/logs/stats/hourly/YYYYMMDD.bin` (append-only, immutable
once the hour closes), `/sdcard/logs/stats/today.bin` (one record,
overwritten in place, lets BLE serve "today so far" without waiting for
midnight), `/sdcard/logs/stats/daily.bin` (append-only, finalized days,
unlimited retention, per D3, aggregates aren't personal data).

## BLE GATT service and characteristic UUIDs

One primary service, three characteristics (vendor-specific 128-bit
UUIDs, randomly generated, no relation to any BLE SIG-adopted service).
PAIRING_STATUS is still not implemented - see docs/ARCHITECTURE.md "BLE
GATT (sketch)".

| Name       | UUID                                   | Properties       |
|------------|-----------------------------------------|-------------------|
| Service    | `e794a7d8-6905-4552-b7a2-d0cdc9dae0f6`  | -                 |
| STATS      | `1b1465c2-296e-4acd-b544-ba1a30ed7f13`  | read, notify      |
| CONFIG     | `c5468eed-52a8-434b-bc6f-0d60c323f07f`  | read, write (bonded only) |
| TIME_SYNC  | `5ebb01c3-8110-4ace-b139-436c1fa0b81f`  | write-only (bonded only) |

## BLE STATS payload: JSON (not CBOR)

Decision and rationale: docs/DECISIONS.md D7. One aggregate row per
notification, never a batch:

```json
{"date":"2026-07-02","hour":14,"unique":37,"returning":22,"kanon":false}
```

Daily record: JSON `null` for `hour` (not the `-1` sentinel from the C
struct; that's a deliberate difference between formats, not a bug to "fix"):

```json
{"date":"2026-07-02","hour":null,"unique":142,"returning":88,"kanon":true}
```

**Chunking:** every row comfortably fits within a realistic MTU (BLE
4.2+ usually negotiates 185-247B). For a very low MTU: a 2-byte fragment
envelope `[uint8 seq_index][uint8 seq_total]` ahead of the raw UTF-8
JSON bytes, the phone reassembles fragments in order. The device should
proactively request an MTU exchange on connect, so fragmentation stays a
rare case.

**Backfill after a longer gap:** the device replays every unsynced row
as consecutive individual STATS notifications (no new batch format),
even after a full 30-day gap that's ~750 rows, trivial for BLE
notification throughput. Tracking "what's already synced with this
bond" (e.g. a per-bond last-synced timestamp in NVS) needs a stable bond
identity, which doesn't exist before Phase 5 (button + bonding); Phase 4
only notifies new records produced while a connection is already active,
it does not replay history on (re)connect. Full backfill is Phase 5
scope, alongside bonding.

## BLE CONFIG payload (read + write)

```json
{"rssi_floor":-85,"returning_window_days":30}
```

`rssi_floor` (dBm) and `returning_window_days` are runtime-configurable
(`firmware/main/runtime_config.c`/`.h`), persisted to NVS, defaulting to
`CONFIG_PRINTBACK_RSSI_FLOOR`/`RETURNING_WINDOW_DAYS`
(firmware/main/aggregate.h) until first written. A write requires both
fields and a bonded/encrypted link (`BLE_GATT_CHR_F_WRITE_ENC`); an
unbonded connection can't even reach this point at all thanks to the
connection whitelist (docs/DECISIONS.md D5). The "reset trigger" from
docs/TASKS.md isn't implemented - no clear definition of what it should
reset yet, not guessed at here.

## BLE TIME_SYNC payload (write-only)

Raw 4 bytes, little-endian `uint32`, unix seconds (UTC) - not JSON. A
single scalar doesn't need the JSON overhead the other two
characteristics have, matching DATA_MODEL.md's opening "Little-endian
everywhere" convention: both sides (Dart's `ByteData` with
`Endian.little`, the RISC-V HP core's native layout) agree on byte order
without any conversion step.

The phone writes this once, right after every successful connection
(docs/DECISIONS.md D6) - not just the first pairing. The device has no
RTC (docs/ARCHITECTURE.md "Wall-clock time"); this is the only way its
clock is ever corrected after the Kconfig fallback at boot
(`sd_storage_set_wallclock_unix_s()`, firmware/main/sd_storage.h). Write
requires a bonded/encrypted link, same reasoning as CONFIG.

**File format header (recommendation, beyond the letter of TASKS.md):**
none of the structs above have a version/magic byte. If the layout ever
changes after Phase 2/3 lands, old `.bin` files become ambiguous.
Recommendation: a 5-byte header per file (4B magic + 1B format version),
cheap now, painful to retrofit later.

## Open questions: deliberately unresolved in this phase

**`is_returning`/`returning_count` algorithm.** Needs a persistent
"seen-on-which-day" index that doesn't exist anywhere today, `tracker.c`
is RAM-only, a 5-minute activity window. We reserve the bit/field in the
format now (so the SD layout doesn't change later), but the algorithm
itself (e.g. scanning the last N days of raw files during the hourly
aggregation run, or a compact per-day on-device index) is a Phase 3
decision, per docs/TASKS.md ("confirm the exact definition with the user").

**Flutter-side aggregate cache format**: Phase 6 TODO, not designing it now.
