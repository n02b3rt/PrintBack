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

    /* sd_format_raw_path: known calendar dates, including month/year boundaries. */
    check_path(20636u, "/sdcard/logs/raw/2026-07-02.bin");
    check_path(20484u, "/sdcard/logs/raw/2026-01-31.bin");
    check_path(20485u, "/sdcard/logs/raw/2026-02-01.bin");
    check_path(21183u, "/sdcard/logs/raw/2027-12-31.bin");
    check_path(21184u, "/sdcard/logs/raw/2028-01-01.bin");
    check_path(0u,     "/sdcard/logs/raw/1970-01-01.bin");

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

    if (failures) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
