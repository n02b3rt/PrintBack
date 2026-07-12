#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fingerprint.h"
#include "wifi_sniffer.h"

#define SD_RAW_FLAG_NEW         (1u << 0)
#define SD_RAW_FLAG_RETURNING   (1u << 1)
#define SD_RAW_FLAG_WHITELISTED (1u << 2)

/* Every .bin file on the SD card opens with this fixed 5-byte header:
 * magic "PBK" + a 1-byte file-type tag + a 1-byte format version. It lets
 * a reader reject a foreign/corrupt/older-format file explicitly (log +
 * treat as empty) instead of blindly decoding whatever bytes it finds as
 * records. Record N in a raw log therefore starts at byte
 * SD_FILE_HEADER_LEN + N*sizeof(sd_raw_record_t), and the same offset
 * shift applies to every stats file. See docs/DATA_MODEL.md "File format". */
#define SD_FILE_HEADER_LEN     5
#define SD_FILE_FORMAT_VERSION 1

typedef enum {
    SD_FILE_TYPE_RAW    = 0,
    SD_FILE_TYPE_HOURLY = 1,
    SD_FILE_TYPE_TODAY  = 2,
    SD_FILE_TYPE_DAILY  = 3,
} sd_file_type_t;

/* Writes the 5-byte header for `type` into `buf` (must be at least
 * SD_FILE_HEADER_LEN bytes). Pure, host-testable. */
void sd_file_header_encode(uint8_t *buf, sd_file_type_t type);

/* True if `buf` (at least SD_FILE_HEADER_LEN bytes) is a valid header for
 * exactly `expected` type at the current format version. A wrong magic,
 * an unknown version, or a mismatched type all return false so the caller
 * can skip the file rather than misread it. Pure, host-testable. */
bool sd_file_header_validate(const uint8_t *buf, sd_file_type_t expected);

/* Format: docs/DATA_MODEL.md "Raw record on SD". Packed, fixed 16 bytes,
 * one record = one probe, append-only in the per-day raw log file. */
typedef struct __attribute__((packed)) {
    uint32_t timestamp_unix_s;
    uint8_t  fp[FINGERPRINT_HASH_BYTES];
    int8_t   rssi;
    uint8_t  channel;
    uint8_t  flags;
    uint8_t  _reserved;
} sd_raw_record_t;

_Static_assert(sizeof(sd_raw_record_t) == 16,
               "sd_raw_record_t must stay 16 bytes, see docs/DATA_MODEL.md");

/* Builds a raw SD record from a probe observation. `unix_s` is the
 * caller-supplied wall-clock time (the device has no RTC, see
 * docs/ARCHITECTURE.md "Wall-clock time"). SD_RAW_FLAG_RETURNING is
 * never set here: that algorithm is deliberately deferred to Phase 3,
 * see docs/DATA_MODEL.md "Open questions". */
void sd_record_from_observation(const probe_observation_t *obs,
                                 uint32_t unix_s, bool fresh, bool whitelisted,
                                 sd_raw_record_t *out);

/* strlen("/sdcard/logs/raw/YYYYMMDD.bin") + 1. Deliberately no dashes in
 * the date: ESP-IDF's FATFS defaults to short 8.3 filenames (LFN is off
 * by default to save RAM), and "YYYY-MM-DD" is a 10-character base name,
 * too long for 8.3. "YYYYMMDD" is exactly 8, fits without needing LFN.
 * Confirmed the hard way: fopen() silently failed on real hardware with
 * the dashed format, see docs/LEARNINGS.md. */
#define SD_RAW_PATH_MAX_LEN 30

/* Formats the raw log path for a given day. `unix_day` = days since
 * 1970-01-01 UTC, same unit as aggregate_record_t.date_unix_day in
 * docs/DATA_MODEL.md. `out` must be at least SD_RAW_PATH_MAX_LEN bytes.
 * Returns 0 on success, -1 if the buffer is too small. */
int sd_format_raw_path(uint32_t unix_day, char *out, size_t out_len);

/* Inverse of the date encoded by sd_format_raw_path: converts a calendar
 * date back to a unix day. Used when scanning the raw log directory for
 * purge, where all sd_storage has to go on is the filename. */
uint32_t sd_unix_day_from_ymd(int year, unsigned month, unsigned day);

/* Converts a unix timestamp (seconds) to a unix day (days since epoch,
 * UTC), the unit sd_format_raw_path and sd_is_purge_candidate use. */
uint32_t sd_unix_day_from_unix_s(uint32_t unix_s);

/* Converts a unix day back to a calendar date (UTC), the same math
 * sd_format_raw_path uses internally to build YYYYMMDD filenames.
 * Exposed publicly for Phase 4: the BLE STATS JSON payload
 * (docs/DATA_MODEL.md) needs a "YYYY-MM-DD" date string built from
 * aggregate_record_t.date_unix_day. */
void sd_civil_from_unix_day(uint32_t unix_day, int *year, unsigned *month, unsigned *day);

/* True if a file dated `file_unix_day` is strictly older than
 * `retention_days` relative to `today_unix_day` and should be purged.
 * A file exactly `retention_days` old is kept (hard limit means "up to
 * and including N days", not "fewer than N days"), matching the
 * kanon_hourly_publishable() "at threshold, publishable" convention in
 * firmware/main/kanon.c. If the file's day is in the future relative to
 * today (clock moved backwards, e.g. before the first BLE time sync),
 * never purge it. */
bool sd_is_purge_candidate(uint32_t file_unix_day, uint32_t today_unix_day,
                            uint32_t retention_days);

/* Extracts the hour-of-day (0-23, UTC) from a unix timestamp. Pure
 * modular arithmetic, no time.h, same portability rationale as
 * civil_from_days in sd_paths.c. */
int sd_hour_from_unix_s(uint32_t unix_s);

/* strlen("/sdcard/logs/stats/hourly/YYYYMMDD.bin") + 1. Shared by all
 * three stats path formatters below (today.bin/daily.bin are shorter,
 * this is just the one buffer size callers need to allocate). */
#define SD_STATS_PATH_MAX_LEN 39

/* Formats "/sdcard/logs/stats/hourly/YYYYMMDD.bin" for a given day.
 * Same unit/contract as sd_format_raw_path. */
int sd_format_stats_hourly_path(uint32_t unix_day, char *out, size_t out_len);

/* Formats the fixed path "/sdcard/logs/stats/today.bin" (single mutable
 * record, no date in the name). */
int sd_format_stats_today_path(char *out, size_t out_len);

/* Formats the fixed path "/sdcard/logs/stats/daily.bin" (append-only,
 * finalized days). */
int sd_format_stats_daily_path(char *out, size_t out_len);

/* Format: docs/DATA_MODEL.md "Aggregate record". Packed, fixed 12 bytes.
 * `hour_or_day`: 0-23 for an hourly bucket, -1 for a whole-day record. */
typedef struct __attribute__((packed)) {
    uint32_t date_unix_day;
    int8_t   hour_or_day;
    uint16_t unique_count;
    uint16_t returning_count;
    uint8_t  k_anonymity_applied;
    uint8_t  _reserved[2];
} aggregate_record_t;

_Static_assert(sizeof(aggregate_record_t) == 12,
               "aggregate_record_t must stay 12 bytes, see docs/DATA_MODEL.md");
