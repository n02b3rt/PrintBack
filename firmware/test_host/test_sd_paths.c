#include <stdio.h>
#include <string.h>
#include "sd_paths.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

static void check_path(uint32_t unix_day, const char *expected)
{
    char buf[SD_RAW_PATH_MAX_LEN];
    int rc = sd_format_raw_path(unix_day, buf, sizeof(buf));
    if (rc != 0 || strcmp(buf, expected) != 0) {
        printf("FAIL: path for unix_day=%u: got \"%s\" (rc=%d), want \"%s\"\n",
               unix_day, buf, rc, expected);
        failures++;
    } else {
        printf("ok: path for unix_day=%u => %s\n", unix_day, expected);
    }
}

int main(void)
{
    /* sd_unix_day_from_unix_s: floors to the start of day, UTC. */
    CHECK(sd_unix_day_from_unix_s(20636u * 86400u)        == 20636u, "unix_day at exact midnight");
    CHECK(sd_unix_day_from_unix_s(20636u * 86400u + 43200u) == 20636u, "unix_day at noon same day");
    CHECK(sd_unix_day_from_unix_s(0) == 0u, "unix_day at epoch");

    /* sd_format_raw_path: known calendar dates, including month/year
     * boundaries. No dashes: FAT short (8.3) filenames only fit an
     * 8-char base name unless LFN is enabled, see sd_paths.h. */
    check_path(20636u, "/sdcard/logs/raw/20260702.bin");
    check_path(20484u, "/sdcard/logs/raw/20260131.bin");
    check_path(20485u, "/sdcard/logs/raw/20260201.bin");
    check_path(21183u, "/sdcard/logs/raw/20271231.bin");
    check_path(21184u, "/sdcard/logs/raw/20280101.bin");
    check_path(0u,     "/sdcard/logs/raw/19700101.bin");

    /* sd_civil_from_unix_day: inverse direction of sd_unix_day_from_ymd,
     * public wrapper around the same civil_from_days math (Phase 4: BLE
     * STATS JSON needs a YYYY-MM-DD string from date_unix_day). */
    {
        int y; unsigned m, d;
        sd_civil_from_unix_day(20636u, &y, &m, &d);
        CHECK(y == 2026 && m == 7 && d == 2, "civil_from_unix_day: 20636 -> 2026-07-02");
        sd_civil_from_unix_day(21184u, &y, &m, &d);
        CHECK(y == 2028 && m == 1 && d == 1, "civil_from_unix_day: 21184 -> 2028-01-01 (leap rollover)");
        sd_civil_from_unix_day(0u, &y, &m, &d);
        CHECK(y == 1970 && m == 1 && d == 1, "civil_from_unix_day: 0 -> epoch");
    }

    /* sd_unix_day_from_ymd: inverse of sd_format_raw_path's date math,
     * exercised on the same set of dates (including the leap-year
     * rollover 2027-12-31 -> 2028-01-01, and the epoch itself). */
    CHECK(sd_unix_day_from_ymd(2026, 7, 2)   == 20636u, "ymd->day: 2026-07-02");
    CHECK(sd_unix_day_from_ymd(2026, 1, 31)  == 20484u, "ymd->day: 2026-01-31");
    CHECK(sd_unix_day_from_ymd(2026, 2, 1)   == 20485u, "ymd->day: 2026-02-01");
    CHECK(sd_unix_day_from_ymd(2027, 12, 31) == 21183u, "ymd->day: 2027-12-31");
    CHECK(sd_unix_day_from_ymd(2028, 1, 1)   == 21184u, "ymd->day: 2028-01-01");
    CHECK(sd_unix_day_from_ymd(1970, 1, 1)   == 0u,     "ymd->day: epoch");

    /* sd_is_purge_candidate: hard 30-day limit means "up to and including
     * 30 days old" is kept, matching kanon_hourly_publishable()'s
     * at-threshold-is-fine convention. */
    CHECK(sd_is_purge_candidate(20636u - 30u, 20636u, 30u) == false, "30 days old: kept, at threshold");
    CHECK(sd_is_purge_candidate(20636u - 31u, 20636u, 30u) == true,  "31 days old: purged");
    CHECK(sd_is_purge_candidate(20636u - 29u, 20636u, 30u) == false, "29 days old: kept");
    CHECK(sd_is_purge_candidate(20636u,       20636u, 30u) == false, "today: kept");
    CHECK(sd_is_purge_candidate(20636u + 5u,  20636u, 30u) == false, "file dated in the future (clock moved backwards before first BLE sync): never purge");

    /* sd_record_from_observation: field mapping + flag bits. */
    probe_observation_t obs = {
        .timestamp_us = 123456789,
        .src_mac = {0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff},
        .rssi = -67,
        .channel = 6,
    };
    memcpy(obs.fp.hash, (uint8_t[FINGERPRINT_HASH_BYTES]){0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04},
           FINGERPRINT_HASH_BYTES);
    obs.fp.ie_count = 11;

    sd_raw_record_t rec;

    sd_record_from_observation(&obs, 1782950400u, false, false, &rec);
    CHECK(rec.timestamp_unix_s == 1782950400u, "record: timestamp copied");
    CHECK(memcmp(rec.fp, obs.fp.hash, FINGERPRINT_HASH_BYTES) == 0, "record: fp bytes copied");
    CHECK(rec.rssi == -67, "record: rssi copied");
    CHECK(rec.channel == 6, "record: channel copied");
    CHECK(rec.flags == 0, "record: neither fresh nor whitelisted => flags 0");
    CHECK(rec._reserved == 0, "record: reserved byte is 0");

    sd_record_from_observation(&obs, 1782950400u, true, false, &rec);
    CHECK(rec.flags == SD_RAW_FLAG_NEW, "record: fresh only => NEW bit only");

    sd_record_from_observation(&obs, 1782950400u, false, true, &rec);
    CHECK(rec.flags == SD_RAW_FLAG_WHITELISTED, "record: whitelisted only => WHITELISTED bit only");

    sd_record_from_observation(&obs, 1782950400u, true, true, &rec);
    CHECK(rec.flags == (SD_RAW_FLAG_NEW | SD_RAW_FLAG_WHITELISTED),
          "record: fresh+whitelisted => both bits, never RETURNING");

    /* sd_hour_from_unix_s: pure modular arithmetic, UTC. */
    CHECK(sd_hour_from_unix_s(1782950400u) == 0,               "hour at midnight");
    CHECK(sd_hour_from_unix_s(1782950400u + 3600u * 14) == 14, "hour at 14:00");
    CHECK(sd_hour_from_unix_s(1782950400u + 3600u * 23 + 3599u) == 23, "hour at 23:59:59");

    /* Stats path formatters (Phase 3), same 8.3-safe convention as raw. */
    {
        char buf[SD_STATS_PATH_MAX_LEN];

        CHECK(sd_format_stats_hourly_path(20636u, buf, sizeof(buf)) == 0 &&
              strcmp(buf, "/sdcard/logs/stats/hourly/20260702.bin") == 0,
              "stats hourly path for 2026-07-02");

        CHECK(sd_format_stats_today_path(buf, sizeof(buf)) == 0 &&
              strcmp(buf, "/sdcard/logs/stats/today.bin") == 0,
              "stats today.bin path");

        CHECK(sd_format_stats_daily_path(buf, sizeof(buf)) == 0 &&
              strcmp(buf, "/sdcard/logs/stats/daily.bin") == 0,
              "stats daily.bin path");
    }

    /* File header (9a): encode/validate round-trips for every type,
     * and a header is rejected on wrong magic, wrong version, or a
     * mismatched type - the three ways a reader must refuse to decode. */
    {
        uint8_t hdr[SD_FILE_HEADER_LEN];
        const sd_file_type_t types[] = {
            SD_FILE_TYPE_RAW, SD_FILE_TYPE_HOURLY,
            SD_FILE_TYPE_TODAY, SD_FILE_TYPE_DAILY,
        };
        for (unsigned i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
            sd_file_header_encode(hdr, types[i]);
            CHECK(sd_file_header_validate(hdr, types[i]) == true,
                  "header: encode/validate round-trips for its own type");
        }

        /* Header written as RAW must not validate as any other type. */
        sd_file_header_encode(hdr, SD_FILE_TYPE_RAW);
        CHECK(sd_file_header_validate(hdr, SD_FILE_TYPE_HOURLY) == false,
              "header: RAW header rejected when TODAY/HOURLY expected");

        /* On-disk layout is exactly magic 'P''B''K' + type + version. */
        CHECK(hdr[0] == 'P' && hdr[1] == 'B' && hdr[2] == 'K' &&
              hdr[3] == (uint8_t)SD_FILE_TYPE_RAW &&
              hdr[4] == SD_FILE_FORMAT_VERSION,
              "header: on-disk byte layout is magic+type+version");

        sd_file_header_encode(hdr, SD_FILE_TYPE_DAILY);
        hdr[0] = 'X';
        CHECK(sd_file_header_validate(hdr, SD_FILE_TYPE_DAILY) == false,
              "header: bad magic rejected");

        sd_file_header_encode(hdr, SD_FILE_TYPE_DAILY);
        hdr[4] = SD_FILE_FORMAT_VERSION + 1;
        CHECK(sd_file_header_validate(hdr, SD_FILE_TYPE_DAILY) == false,
              "header: unknown format version rejected");
    }

    if (failures) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
