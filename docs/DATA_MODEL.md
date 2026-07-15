# Data model: PrintBack (BLE + SD)

Formats for the target architecture (`refactor/ble-sd-flutter`), context:
[docs/ARCHITECTURE.md](ARCHITECTURE.md). Little-endian everywhere (RISC-V HP
core on the C6), matters for any future tool (Flutter, desktop) that ever
reads raw `.bin` files directly.

## File format (versioned header)

Every `.bin` file on the SD card starts with a fixed 5-byte header,
followed by the file's records:

```
byte 0..2  magic  "PBK"
byte 3     type   0=raw, 1=hourly, 2=today, 3=daily
byte 4     version  format version (currently 1)
```

Records therefore start at byte 5: record N in a raw log is at offset
`5 + N*16`, and the single `today.bin` record is at offset 5. On open, a
reader validates magic+type+version and skips the file (logs a warning,
treats it as empty) on any mismatch, rather than decoding foreign or
older-format bytes as records. The pure encode/validate helpers live in
`firmware/main/sd_paths.c` (`sd_file_header_encode`/
`sd_file_header_validate`, host-tested); each writer lays the header down
when it first creates a file, each reader skips it before its record loop.
There is no in-place migration of pre-header files: a card written by an
older firmware is wiped before use (no production data yet).

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
records after the 5-byte header (see "File format" above), record N sits
at offset 5 + N×16, trivial seek/truncate for the 30-day purge. No dashes
in the date: FAT short (8.3) filenames don't fit `YYYY-MM-DD` without
enabling Long File Name support, learned the hard way on real hardware,
see docs/LEARNINGS.md.

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

One primary service, five characteristics (vendor-specific 128-bit
UUIDs, randomly generated, no relation to any BLE SIG-adopted service).
PAIRING_STATUS is still not implemented - see docs/ARCHITECTURE.md "BLE
GATT (sketch)".

| Name       | UUID                                   | Properties       |
|------------|-----------------------------------------|-------------------|
| Service    | `e794a7d8-6905-4552-b7a2-d0cdc9dae0f6`  | -                 |
| STATS      | `1b1465c2-296e-4acd-b544-ba1a30ed7f13`  | read, notify      |
| CONFIG     | `c5468eed-52a8-434b-bc6f-0d60c323f07f`  | read, write (bonded only) |
| TIME_SYNC  | `5ebb01c3-8110-4ace-b139-436c1fa0b81f`  | write-only (bonded only) |
| SYNC       | `8f2c1e40-7bb5-4b9f-9e11-3c6b9d5a2f77`  | write-only (bonded only) |
| STATUS     | `cf2c77c3-71e7-4121-a695-e22fdbcbe4ba`  | read-only         |

## BLE STATUS payload (read-only)

Device diagnostics, one JSON object, read on demand (never notified). All
fields are live device state, never per-client data:

```json
{"fw":"1.0.0","sd_ok":true,"sd_free_mb":59421,"uptime_s":86321,"heap":142000,"reset":"poweron","wl":14}
```

`fw` is `esp_app_get_description()->version` (from the git tag / CMake
project version), `sd_ok`/`sd_free_mb` come from `sd_storage`, `uptime_s`
from `esp_timer`, `heap` from `esp_get_free_heap_size()`, `reset` is
the last reset reason string (`poweron`/`panic`/`brownout`/... captured at
boot), and `wl` is `whitelist_count()` - the total whitelist size
(auto-whitelisted background devices + any manually armed). `wl` is an
aggregate count only, never a fingerprint, so it carries no per-client
data; the app shows it as "background devices excluded from the visitor
count". Read-only, no encryption flag - same as STATS, and only bonded
peers reach it through the connection whitelist anyway. A phone treats the
characteristic as optional: older firmware without it must not break the
connect flow (Etap 2 mobile `readStatus()` uses a null-returning lookup,
not a throwing one).

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

**Backfill after a longer gap:** implemented in Phase 8 via the SYNC
characteristic below - the device replays unsynced daily rows as
consecutive individual STATS notifications (no new batch format on this
one either), same JSON as a live rollover notify. See "BLE SYNC payload"
below for the protocol; docs/DECISIONS.md D10 for why the device doesn't
track per-bond sync state itself. Hourly detail is backfilled too, not
just daily totals (9d): after the daily backlog, SYNC replays the hourly
files for the last 7 days (`today-7 .. today-1`) and then today's own
hours from `stats/hourly/<today>.bin`, so a phone that was away for days
still gets a real per-hour pattern. The dashboard's hourly chart would
otherwise stay empty until a live hour-boundary notification happened to
arrive during some future connection, confirmed as a real (not cosmetic)
problem on hardware.

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

## BLE SYNC payload (write-only)

Raw 4 bytes, little-endian `uint32` `since_unix_day` (days since
1970-01-01 UTC, same unit as `aggregate_record_t.date_unix_day`) - not
JSON, same reasoning as TIME_SYNC. `0` means "send everything".

The phone already knows the newest date it has stored locally, so it
computes `since_unix_day` itself (typically "latest local date + 1") and
writes it once per connection, right after TIME_SYNC. The device replays
the backlog in three phases (`firmware/main/ble_gatt.c`'s `sync_tick_cb()`,
paced off a dedicated timer so a large backlog doesn't block the NimBLE
host task - see docs/DECISIONS.md D10), all as ordinary STATS
notifications:

1. every `stats/daily.bin` record with `date_unix_day >= since_unix_day`,
   oldest first;
2. the hourly files for the last 7 days (`today-7 .. today-1`), a day at a
   time, each day's hours in order - unconditional, not gated by
   `since_unix_day`, so a phone away for several days still gets per-hour
   detail, not just daily totals (9d);
3. today's already-finalized hours from `stats/hourly/<today>.bin`.

Phases 2 and 3 are bounded (at most `8*24` records) and the phone's local
dedup makes a repeat replay a harmless no-op, so neither needs its own
cursor on the device. When all three phases finish, the device sends one
end-of-sync marker: a STATS notify with `date_unix_day == 0`
(`1970-01-01`, a date no real aggregate ever has), so the phone can flip
its "syncing" state off immediately rather than waiting on a timeout. The
phone filters that row out before storing it; an older app that doesn't
know the marker just drops an unrenderable 1970 row, and older firmware
that never sends one falls back to the phone's ~1.5s idle-gap heuristic -
backward compatible both ways. Write requires a bonded/encrypted link,
same reasoning as CONFIG/TIME_SYNC.

## Open questions: deliberately unresolved in this phase

**`is_returning`/`returning_count` algorithm.** Needs a persistent
"seen-on-which-day" index that doesn't exist anywhere today, `tracker.c`
is RAM-only, a 5-minute activity window. We reserve the bit/field in the
format now (so the SD layout doesn't change later), but the algorithm
itself (e.g. scanning the last N days of raw files during the hourly
aggregation run, or a compact per-day on-device index) is a Phase 3
decision, per docs/TASKS.md ("confirm the exact definition with the user").

**Flutter-side aggregate cache format**: Phase 6 TODO, not designing it now.
