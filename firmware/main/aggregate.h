#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "sd_paths.h"

/* Business decision, confirmed with the user in Phase 3: a device counts
 * as "returning" if its fp was seen on any of the previous 30 calendar
 * days, matching returning_window_days in the old desktop app's config
 * (app/printback/config.py, docs/compliance/README.md). Public (not just
 * in aggregate.c) so the Phase 4 BLE CONFIG characteristic can report the
 * same value it's actually using, zero risk of the two drifting apart. */
#define RETURNING_WINDOW_DAYS 30

/* Runs hourly aggregation for the hour that just ended (`completed_hour`,
 * 0-23) on day `unix_day`. Scans today's raw log for that hour, counts
 * unique non-whitelisted fingerprints and how many are "returning"
 * (seen on an earlier day within the last 30 days, docs/DECISIONS.md
 * "returning window"), applies the k-anonymity threshold
 * (kanon_hourly_publishable(), firmware/main/kanon.c) to decide whether
 * an hourly record gets published or folded into the running daily
 * total, then recomputes and overwrites today's running daily total.
 * No-op if the SD card isn't mounted (sd_storage_is_ready()).
 *
 * If `out_record` is non-NULL and this returns true, `*out_record` holds
 * the record a BLE STATS notify should report for this run: the hourly
 * record if it passed k-anonymity, otherwise the updated today-so-far
 * record (the k-anonymity fold-in is itself the news, Phase 4). Returns
 * false (out_record untouched) if the SD card isn't mounted. */
bool aggregate_run_hourly(uint32_t unix_day, int completed_hour,
                           aggregate_record_t *out_record);

/* Runs once when the day rolls over to `new_unix_day`: finalizes the
 * previous day's running total (stats/today.bin) into stats/daily.bin,
 * and rebuilds the 30-day "seen before" history set used to compute
 * returning_count for the whole new day. No-op if the SD card isn't
 * mounted.
 *
 * If `out_record` is non-NULL and this returns true, `*out_record` holds
 * the just-finalized daily record (Phase 4 BLE STATS notify). Returns
 * false (out_record untouched) if the SD card isn't mounted or there was
 * no today.bin to finalize (e.g. first day after a fresh SD card). */
bool aggregate_run_daily_rollover(uint32_t new_unix_day,
                                   aggregate_record_t *out_record);
