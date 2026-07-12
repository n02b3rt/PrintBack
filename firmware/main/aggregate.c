#include "aggregate.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"

#include "fingerprint.h"
#include "kanon.h"
#include "runtime_config.h"
#include "sd_paths.h"
#include "sd_storage.h"

static const char *TAG = "aggregate";

/* RETURNING_WINDOW_DAYS is now public, see aggregate.h. */

/* Scratch space for a single scan_day() call (one hour, or "today so
 * far"). Sized for a busy hour/day in a small retail deployment, not a
 * stadium; log + truncate rather than overflow if ever exceeded. */
#define MAX_SCAN_UNIQUE 512
static uint8_t  s_scan_fps[MAX_SCAN_UNIQUE][FINGERPRINT_HASH_BYTES];
static uint16_t s_scan_count;

/* 30-day "seen before" set, rebuilt once per day at rollover. */
#define MAX_HISTORY_UNIQUE 4096
static uint8_t  s_history_fps[MAX_HISTORY_UNIQUE][FINGERPRINT_HASH_BYTES];
static uint16_t s_history_count;

/* True if any hour so far today failed the k-anonymity threshold and
 * got folded into the running daily total instead of published on its
 * own. Reset at every daily rollover. */
static bool s_today_kanon_applied;

/* Reads and validates the 5-byte header at the start of an open SD file,
 * leaving the read position just past it. Returns false (and logs) on a
 * short read or a header that isn't a valid `type` at the current format
 * version, so the caller treats the file as empty instead of decoding
 * stale/foreign bytes as records (9a, docs/DATA_MODEL.md "File format"). */
static bool skip_valid_header(FILE *f, sd_file_type_t type, const char *what)
{
    uint8_t hdr[SD_FILE_HEADER_LEN];
    if (fread(hdr, sizeof(hdr), 1, f) != 1 ||
        !sd_file_header_validate(hdr, type)) {
        ESP_LOGW(TAG, "%s: missing/invalid file header, treating as empty", what);
        return false;
    }
    return true;
}

/* Writes the versioned header for `type` if `f` is a freshly-created
 * (empty) file, no-op otherwise. Call right after opening in append mode
 * and before the first record. */
static void write_header_if_new(FILE *f, sd_file_type_t type)
{
    fseek(f, 0, SEEK_END);
    if (ftell(f) != 0) return;
    uint8_t hdr[SD_FILE_HEADER_LEN];
    sd_file_header_encode(hdr, type);
    fwrite(hdr, sizeof(hdr), 1, f);
}

static bool fp_in(const uint8_t fps[][FINGERPRINT_HASH_BYTES], uint16_t count,
                   const uint8_t *fp)
{
    for (uint16_t i = 0; i < count; i++) {
        if (memcmp(fps[i], fp, FINGERPRINT_HASH_BYTES) == 0) return true;
    }
    return false;
}

static bool history_contains(const uint8_t *fp)
{
    return fp_in(s_history_fps, s_history_count, fp);
}

/* Scans today's raw log and counts unique non-whitelisted fingerprints,
 * plus how many of them are in the returning-history set. `hour_filter`
 * restricts to one hour (0-23), or -1 for the whole day so far. Reuses
 * s_scan_fps/s_scan_count as scratch (single-threaded: only ever called
 * from the housekeeper task, never concurrently). */
static void scan_day(uint32_t unix_day, int hour_filter,
                      uint16_t *unique_out, uint16_t *returning_out)
{
    s_scan_count = 0;
    *unique_out = 0;
    *returning_out = 0;

    char path[SD_RAW_PATH_MAX_LEN];
    if (sd_format_raw_path(unix_day, path, sizeof(path)) != 0) return;

    FILE *f = fopen(path, "rb");
    if (!f) {
        ESP_LOGW(TAG, "scan_day: could not open %s for reading (errno=%d)", path, errno);
        return;
    }
    if (!skip_valid_header(f, SD_FILE_TYPE_RAW, "scan_day")) {
        fclose(f);
        return;
    }

    uint16_t returning = 0;
    sd_raw_record_t rec;
    while (fread(&rec, sizeof(rec), 1, f) == 1) {
        if (rec.flags & SD_RAW_FLAG_WHITELISTED) continue;
        if (hour_filter >= 0 && sd_hour_from_unix_s(rec.timestamp_unix_s) != hour_filter) continue;
        if (fp_in(s_scan_fps, s_scan_count, rec.fp)) continue;

        if (s_scan_count >= MAX_SCAN_UNIQUE) {
            ESP_LOGW(TAG, "scan_day: unique cap (%d) reached, undercounting", MAX_SCAN_UNIQUE);
            break;
        }
        memcpy(s_scan_fps[s_scan_count++], rec.fp, FINGERPRINT_HASH_BYTES);
        if (history_contains(rec.fp)) returning++;
    }
    fclose(f);

    *unique_out = s_scan_count;
    *returning_out = returning;
}

static aggregate_record_t write_stats_hourly(uint32_t unix_day, int hour,
                                              uint16_t unique_count, uint16_t returning_count)
{
    aggregate_record_t rec = {
        .date_unix_day = unix_day,
        .hour_or_day = (int8_t)hour,
        .unique_count = unique_count,
        .returning_count = returning_count,
        .k_anonymity_applied = 0,
    };

    char path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_hourly_path(unix_day, path, sizeof(path)) != 0) return rec;

    FILE *f = fopen(path, "ab");
    if (!f) {
        ESP_LOGE(TAG, "failed to open %s for append", path);
        return rec;
    }
    write_header_if_new(f, SD_FILE_TYPE_HOURLY);
    if (fwrite(&rec, sizeof(rec), 1, f) != 1) {
        ESP_LOGW(TAG, "hourly stats write failed");
    }
    fclose(f);
    return rec;
}

static aggregate_record_t write_stats_today(uint32_t unix_day, uint16_t unique_count,
                                             uint16_t returning_count)
{
    aggregate_record_t rec = {
        .date_unix_day = unix_day,
        .hour_or_day = -1,
        .unique_count = unique_count,
        .returning_count = returning_count,
        .k_anonymity_applied = s_today_kanon_applied ? 1 : 0,
    };

    char path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_today_path(path, sizeof(path)) != 0) return rec;

    FILE *f = fopen(path, "wb"); /* one mutable record, overwritten in place */
    if (!f) {
        ESP_LOGE(TAG, "failed to open %s for write", path);
        return rec;
    }
    uint8_t hdr[SD_FILE_HEADER_LEN];
    sd_file_header_encode(hdr, SD_FILE_TYPE_TODAY);
    fwrite(hdr, sizeof(hdr), 1, f);
    if (fwrite(&rec, sizeof(rec), 1, f) != 1) {
        ESP_LOGW(TAG, "today.bin write failed");
    }
    fclose(f);
    return rec;
}

bool aggregate_run_hourly(uint32_t unix_day, int completed_hour,
                           aggregate_record_t *out_record)
{
    if (!sd_storage_is_ready()) return false;

    uint16_t hour_unique, hour_returning;
    scan_day(unix_day, completed_hour, &hour_unique, &hour_returning);

    bool publishable = kanon_hourly_publishable((int)hour_unique);
    aggregate_record_t hourly_rec = {0};
    if (publishable) {
        hourly_rec = write_stats_hourly(unix_day, completed_hour, hour_unique, hour_returning);
    } else {
        s_today_kanon_applied = true;
    }

    uint16_t day_unique, day_returning;
    scan_day(unix_day, -1, &day_unique, &day_returning);
    aggregate_record_t today_rec = write_stats_today(unix_day, day_unique, day_returning);

    if (out_record) {
        *out_record = publishable ? hourly_rec : today_rec;
    }

    ESP_LOGI(TAG, "hour %02d: unique=%u returning=%u published=%s | "
             "today so far: unique=%u returning=%u",
             completed_hour, hour_unique, hour_returning,
             publishable ? "yes" : "no", day_unique, day_returning);
    return true;
}

bool aggregate_run_daily_rollover(uint32_t new_unix_day, aggregate_record_t *out_record)
{
    if (!sd_storage_is_ready()) return false;

    /* today.bin already holds the complete previous day's totals (the
     * hour-23 aggregate_run_hourly() call updates it one last time
     * before midnight), just finalize it into daily.bin. */
    bool have_rec = false;
    aggregate_record_t rec = {0};
    char today_path[SD_STATS_PATH_MAX_LEN];
    char daily_path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_today_path(today_path, sizeof(today_path)) == 0 &&
        sd_format_stats_daily_path(daily_path, sizeof(daily_path)) == 0) {
        FILE *tf = fopen(today_path, "rb");
        if (tf) {
            if (skip_valid_header(tf, SD_FILE_TYPE_TODAY, "rollover today.bin") &&
                fread(&rec, sizeof(rec), 1, tf) == 1) {
                have_rec = true;
                FILE *df = fopen(daily_path, "ab");
                if (df) {
                    write_header_if_new(df, SD_FILE_TYPE_DAILY);
                    if (fwrite(&rec, sizeof(rec), 1, df) != 1) {
                        ESP_LOGW(TAG, "daily.bin write failed");
                    }
                    fclose(df);
                } else {
                    ESP_LOGE(TAG, "failed to open %s for append", daily_path);
                }
            }
            fclose(tf);
        }
    }

    if (out_record && have_rec) {
        *out_record = rec;
    }

    s_today_kanon_applied = false;

    /* Rebuild the returning-window history set for the new day's
     * returning_count. Window length is runtime-configurable (Phase 5,
     * BLE CONFIG write), default RETURNING_WINDOW_DAYS. Files older than
     * this may already be purged (Phase 2, 30-day raw retention) - a
     * missing file just means no history from that day, not an error. */
    uint8_t returning_window_days = runtime_config_returning_window_days();
    s_history_count = 0;
    for (uint32_t d = new_unix_day - returning_window_days; d < new_unix_day; d++) {
        char path[SD_RAW_PATH_MAX_LEN];
        if (sd_format_raw_path(d, path, sizeof(path)) != 0) continue;
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        if (!skip_valid_header(f, SD_FILE_TYPE_RAW, "history rebuild")) {
            fclose(f);
            continue;
        }

        sd_raw_record_t raw_rec;
        while (fread(&raw_rec, sizeof(raw_rec), 1, f) == 1) {
            if (raw_rec.flags & SD_RAW_FLAG_WHITELISTED) continue;
            if (history_contains(raw_rec.fp)) continue;
            if (s_history_count >= MAX_HISTORY_UNIQUE) {
                ESP_LOGW(TAG, "history cap (%d) reached, returning_count may undercount",
                         MAX_HISTORY_UNIQUE);
                break;
            }
            memcpy(s_history_fps[s_history_count++], raw_rec.fp, FINGERPRINT_HASH_BYTES);
        }
        fclose(f);
    }

    ESP_LOGI(TAG, "daily rollover: history set rebuilt, %u unique fp over last %u days",
             s_history_count, returning_window_days);
    return have_rec;
}
