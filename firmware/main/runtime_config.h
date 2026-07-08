#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Loads persisted RSSI floor / returning-window values from NVS, falling
 * back to the compile-time defaults (CONFIG_PRINTBACK_RSSI_FLOOR,
 * RETURNING_WINDOW_DAYS from aggregate.h) if nothing is stored yet. Call
 * once at boot, before the first probe/aggregation run needs these
 * values. */
void runtime_config_init(void);

/* Current effective values - what on_probe()'s RSSI filter and
 * aggregate.c's returning-window history rebuild use instead of reading
 * the compile-time constants directly. Safe to call from any task. */
int8_t runtime_config_rssi_floor(void);
uint8_t runtime_config_returning_window_days(void);

/* Parses, validates and persists a new CONFIG value from a BLE write
 * (docs/DATA_MODEL.md "BLE CONFIG payload" JSON format). `json` must be
 * null-terminated. Returns false (nothing changed, nothing persisted) if
 * the JSON is malformed, missing a field, or out of range
 * (runtime_config_parse.h limits) - see that header for the pure
 * extraction/validation this wraps. */
bool runtime_config_apply_json(const char *json, size_t len);
