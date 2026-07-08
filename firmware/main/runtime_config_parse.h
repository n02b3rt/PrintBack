#pragma once

#include <stdbool.h>
#include <stddef.h>

/* Range limits for the two BLE CONFIG fields (docs/DATA_MODEL.md "BLE
 * CONFIG payload"). Public so runtime_config.c's Kconfig-fallback path
 * and any future doc generation can reference the same numbers, single
 * source of truth. */
#define RUNTIME_CONFIG_RSSI_FLOOR_MIN (-100)
#define RUNTIME_CONFIG_RSSI_FLOOR_MAX (-20)
#define RUNTIME_CONFIG_RETURNING_WINDOW_DAYS_MIN 1
#define RUNTIME_CONFIG_RETURNING_WINDOW_DAYS_MAX 90

/* Extracts "rssi_floor" and "returning_window_days" integer fields from a
 * JSON object (docs/DATA_MODEL.md CONFIG payload format), e.g.
 * {"rssi_floor":-85,"returning_window_days":30}. Deliberately not a
 * general JSON parser (docs/DECISIONS.md D7: no new on-device dependency
 * for a two-field object) - just enough string search + strtol to pull
 * these two known keys out, in either order. `json` must be a
 * null-terminated string; `len` is a defensive non-zero check, not used
 * to bound the search itself. Returns false (outputs untouched) if
 * either key is missing or has no parseable integer after it. */
bool runtime_config_extract_json(const char *json, size_t len,
                                  int *rssi_floor_out, int *returning_window_days_out);

/* True if both values fall within the sane ranges above. Pure range
 * check, no I/O - the caller (runtime_config_apply_json) decides what to
 * do with an invalid result. */
bool runtime_config_validate(int rssi_floor, int returning_window_days);
