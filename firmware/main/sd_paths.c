#include "sd_paths.h"

#include <stdio.h>
#include <string.h>

/* Converts days since 1970-01-01 (UTC, proleptic Gregorian) into
 * (year, month, day) with pure integer arithmetic, no libc time.h
 * dependency. Deliberately avoids gmtime_r(): it's not available on
 * every host toolchain (missing on the MinGW/TDM-GCC build used for
 * `firmware/test_host`), and this module is supposed to stay plain,
 * portable C, buildable with any gcc. Algorithm: Howard Hinnant,
 * "chrono-Compatible Low-Level Date Algorithms",
 * https://howardhinnant.github.io/date_algorithms.html#civil_from_days */
static void civil_from_days(int64_t z, int *y, unsigned *m, unsigned *d)
{
    z += 719468; /* shift epoch from 1970-01-01 to 0000-03-01 */
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);                     /* [0, 146096] */
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; /* [0, 399] */
    int64_t yr = (int64_t)yoe + era * 400;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);          /* [0, 365] */
    unsigned mp = (5 * doy + 2) / 153;                               /* [0, 11] */
    unsigned day = doy - (153 * mp + 2) / 5 + 1;                     /* [1, 31] */
    unsigned month = mp + (mp < 10 ? 3 : (unsigned)-9);              /* [1, 12] */
    *y = (int)(yr + (month <= 2));
    *m = month;
    *d = day;
}

void sd_record_from_observation(const probe_observation_t *obs,
                                 uint32_t unix_s, bool fresh, bool whitelisted,
                                 sd_raw_record_t *out)
{
    memset(out, 0, sizeof(*out));
    out->timestamp_unix_s = unix_s;
    memcpy(out->fp, obs->fp.hash, FINGERPRINT_HASH_BYTES);
    out->rssi = obs->rssi;
    out->channel = obs->channel;
    if (fresh)       out->flags |= SD_RAW_FLAG_NEW;
    if (whitelisted) out->flags |= SD_RAW_FLAG_WHITELISTED;
}

uint32_t sd_unix_day_from_unix_s(uint32_t unix_s)
{
    return unix_s / 86400u;
}

void sd_civil_from_unix_day(uint32_t unix_day, int *year, unsigned *month, unsigned *day)
{
    civil_from_days((int64_t)unix_day, year, month, day);
}

/* Inverse of civil_from_days. Same source: Howard Hinnant,
 * "chrono-Compatible Low-Level Date Algorithms",
 * https://howardhinnant.github.io/date_algorithms.html#days_from_civil */
uint32_t sd_unix_day_from_ymd(int year, unsigned month, unsigned day)
{
    int64_t y = year - (month <= 2 ? 1 : 0);
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);                                /* [0, 399] */
    unsigned doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1; /* [0, 365] */
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;                    /* [0, 146096] */
    return (uint32_t)(era * 146097 + (int64_t)doe - 719468);
}

int sd_format_raw_path(uint32_t unix_day, char *out, size_t out_len)
{
    if (out_len < SD_RAW_PATH_MAX_LEN) return -1;

    int y; unsigned m, d;
    civil_from_days((int64_t)unix_day, &y, &m, &d);

    int n = snprintf(out, out_len, "/sdcard/logs/raw/%04d%02u%02u.bin", y, m, d);
    return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

bool sd_is_purge_candidate(uint32_t file_unix_day, uint32_t today_unix_day,
                            uint32_t retention_days)
{
    if (file_unix_day > today_unix_day) return false;
    uint32_t age_days = today_unix_day - file_unix_day;
    return age_days > retention_days;
}

int sd_hour_from_unix_s(uint32_t unix_s)
{
    return (int)((unix_s % 86400u) / 3600u);
}

int sd_format_stats_hourly_path(uint32_t unix_day, char *out, size_t out_len)
{
    if (out_len < SD_STATS_PATH_MAX_LEN) return -1;

    int y; unsigned m, d;
    civil_from_days((int64_t)unix_day, &y, &m, &d);

    int n = snprintf(out, out_len, "/sdcard/logs/stats/hourly/%04d%02u%02u.bin", y, m, d);
    return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

int sd_format_stats_today_path(char *out, size_t out_len)
{
    if (out_len < SD_STATS_PATH_MAX_LEN) return -1;
    int n = snprintf(out, out_len, "/sdcard/logs/stats/today.bin");
    return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}

int sd_format_stats_daily_path(char *out, size_t out_len)
{
    if (out_len < SD_STATS_PATH_MAX_LEN) return -1;
    int n = snprintf(out, out_len, "/sdcard/logs/stats/daily.bin");
    return (n > 0 && (size_t)n < out_len) ? 0 : -1;
}
