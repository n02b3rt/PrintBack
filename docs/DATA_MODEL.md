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
bond" (e.g. a per-bond last-synced timestamp in NVS) is a Phase 4/5
implementation detail.

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
