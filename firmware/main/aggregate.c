#include "aggregate.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"

#include "fingerprint.h"
#include "kanon.h"
#include "sd_paths.h"
#include "sd_storage.h"

static const char *TAG = "aggregate";

/* Business decision, confirmed with the user this session: a device
 * counts as "returning" if its fp was seen on any of the previous 30
 * calendar days, matching returning_window_days in the old desktop
 * app's config (app/printback/config.py, docs/compliance/README.md). */
#define RETURNING_WINDOW_DAYS 30

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

static void write_stats_hourly(uint32_t unix_day, int hour,
                                uint16_t unique_count, uint16_t returning_count)
{
    char path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_hourly_path(unix_day, path, sizeof(path)) != 0) return;

    aggregate_record_t rec = {
        .date_unix_day = unix_day,
        .hour_or_day = (int8_t)hour,
        .unique_count = unique_count,
        .returning_count = returning_count,
        .k_anonymity_applied = 0,
    };

    FILE *f = fopen(path, "ab");
    if (!f) {
        ESP_LOGE(TAG, "failed to open %s for append", path);
        return;
    }
    if (fwrite(&rec, sizeof(rec), 1, f) != 1) {
        ESP_LOGW(TAG, "hourly stats write failed");
    }
    fclose(f);
}

static void write_stats_today(uint32_t unix_day, uint16_t unique_count,
                               uint16_t returning_count)
{
    char path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_today_path(path, sizeof(path)) != 0) return;

    aggregate_record_t rec = {
        .date_unix_day = unix_day,
        .hour_or_day = -1,
        .unique_count = unique_count,
        .returning_count = returning_count,
        .k_anonymity_applied = s_today_kanon_applied ? 1 : 0,
    };

    FILE *f = fopen(path, "wb"); /* one mutable record, overwritten in place */
    if (!f) {
        ESP_LOGE(TAG, "failed to open %s for write", path);
        return;
    }
    if (fwrite(&rec, sizeof(rec), 1, f) != 1) {
        ESP_LOGW(TAG, "today.bin write failed");
    }
    fclose(f);
}

void aggregate_run_hourly(uint32_t unix_day, int completed_hour)
{
    if (!sd_storage_is_ready()) return;

    uint16_t hour_unique, hour_returning;
    scan_day(unix_day, completed_hour, &hour_unique, &hour_returning);

    bool publishable = kanon_hourly_publishable((int)hour_unique);
    if (publishable) {
        write_stats_hourly(unix_day, completed_hour, hour_unique, hour_returning);
    } else {
        s_today_kanon_applied = true;
    }

    uint16_t day_unique, day_returning;
    scan_day(unix_day, -1, &day_unique, &day_returning);
    write_stats_today(unix_day, day_unique, day_returning);

    ESP_LOGI(TAG, "hour %02d: unique=%u returning=%u published=%s | "
             "today so far: unique=%u returning=%u",
             completed_hour, hour_unique, hour_returning,
             publishable ? "yes" : "no", day_unique, day_returning);
}

void aggregate_run_daily_rollover(uint32_t new_unix_day)
{
    if (!sd_storage_is_ready()) return;

    /* today.bin already holds the complete previous day's totals (the
     * hour-23 aggregate_run_hourly() call updates it one last time
     * before midnight), just finalize it into daily.bin. */
    char today_path[SD_STATS_PATH_MAX_LEN];
    char daily_path[SD_STATS_PATH_MAX_LEN];
    if (sd_format_stats_today_path(today_path, sizeof(today_path)) == 0 &&
        sd_format_stats_daily_path(daily_path, sizeof(daily_path)) == 0) {
        FILE *tf = fopen(today_path, "rb");
        if (tf) {
            aggregate_record_t rec;
            if (fread(&rec, sizeof(rec), 1, tf) == 1) {
                FILE *df = fopen(daily_path, "ab");
                if (df) {
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

    s_today_kanon_applied = false;

    /* Rebuild the 30-day history set for the new day's returning_count.
     * Files older than this may already be purged (Phase 2, 30-day raw
     * retention) - a missing file just means no history from that day,
     * not an error. */
    s_history_count = 0;
    for (uint32_t d = new_unix_day - RETURNING_WINDOW_DAYS; d < new_unix_day; d++) {
        char path[SD_RAW_PATH_MAX_LEN];
        if (sd_format_raw_path(d, path, sizeof(path)) != 0) continue;
        FILE *f = fopen(path, "rb");
        if (!f) continue;

        sd_raw_record_t rec;
        while (fread(&rec, sizeof(rec), 1, f) == 1) {
            if (rec.flags & SD_RAW_FLAG_WHITELISTED) continue;
            if (history_contains(rec.fp)) continue;
            if (s_history_count >= MAX_HISTORY_UNIQUE) {
                ESP_LOGW(TAG, "history cap (%d) reached, returning_count may undercount",
                         MAX_HISTORY_UNIQUE);
                break;
            }
            memcpy(s_history_fps[s_history_count++], rec.fp, FINGERPRINT_HASH_BYTES);
        }
        fclose(f);
    }

    ESP_LOGI(TAG, "daily rollover: history set rebuilt, %u unique fp over last %d days",
             s_history_count, RETURNING_WINDOW_DAYS);
}
