#pragma once

#include <stdint.h>

/* Runs hourly aggregation for the hour that just ended (`completed_hour`,
 * 0-23) on day `unix_day`. Scans today's raw log for that hour, counts
 * unique non-whitelisted fingerprints and how many are "returning"
 * (seen on an earlier day within the last 30 days, docs/DECISIONS.md
 * "returning window"), applies the k-anonymity threshold
 * (kanon_hourly_publishable(), firmware/main/kanon.c) to decide whether
 * an hourly record gets published or folded into the running daily
 * total, then recomputes and overwrites today's running daily total.
 * No-op if the SD card isn't mounted (sd_storage_is_ready()). */
void aggregate_run_hourly(uint32_t unix_day, int completed_hour);

/* Runs once when the day rolls over to `new_unix_day`: finalizes the
 * previous day's running total (stats/today.bin) into stats/daily.bin,
 * and rebuilds the 30-day "seen before" history set used to compute
 * returning_count for the whole new day. No-op if the SD card isn't
 * mounted. */
void aggregate_run_daily_rollover(uint32_t new_unix_day);
