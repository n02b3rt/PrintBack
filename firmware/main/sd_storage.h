#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#include "wifi_sniffer.h"

/* Mounts the SD card over SPI (pins: Kconfig PRINTBACK_PIN_SD_*) and
 * prepares the raw log directory. Safe to call even without a card
 * present: logs the error once and returns it, the rest of the
 * firmware (WiFi sniffing, whitelist, USB output) keeps running with SD
 * logging simply disabled, since a missing/damaged card is not a
 * reason to stop sniffing. */
esp_err_t sd_storage_init(void);

/* True once sd_storage_init() has successfully mounted the card. */
bool sd_storage_is_ready(void);

/* Writes one raw record (docs/DATA_MODEL.md) for this observation to
 * today's raw log file. No-op if the card isn't mounted. Detects day
 * rollover on its own and opens a new file when the day changes. */
void sd_storage_write_raw(const probe_observation_t *obs, bool fresh, bool whitelisted);

/* Sets/corrects the wall clock: `unix_s` is the current UTC unix time.
 * Called once at boot from the Kconfig fallback (no RTC on this board,
 * see docs/ARCHITECTURE.md "Wall-clock time"), and later by BLE time
 * sync once Phase 4/5 lands (docs/DECISIONS.md D6). */
void sd_storage_set_wallclock_unix_s(uint32_t unix_s);

/* Bytes written so far to the currently-open raw file (0 if none open
 * or SD not ready). Operational visibility only, so "is SD actually
 * accumulating data" is answerable from the serial log without pulling
 * the card. */
uint32_t sd_storage_raw_bytes_written(void);

/* Deletes raw log files older than `retention_days` (docs/ARCHITECTURE.md
 * "SD layout"). Called once at init and again on every day rollover, so
 * callers outside sd_storage.c normally don't need to call this
 * directly. No-op if the card isn't mounted. */
void sd_storage_purge_old(uint32_t retention_days);
