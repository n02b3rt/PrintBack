#pragma once

#include "sd_paths.h"

/* Starts the NimBLE host stack: registers the GATT service (STATS +
 * CONFIG characteristics, docs/DATA_MODEL.md for the UUIDs and payload
 * format) and begins advertising. Runs its own host task internally
 * (nimble_port_freertos_init), no separate xTaskCreate needed from
 * main.c. Call once from app_main(), after wifi_sniffer_start() (see
 * docs/ARCHITECTURE.md "Coexistence": both stacks share the single HP
 * core, ESP_COEX_SW_COEXIST_ENABLE arbitrates radio access between them
 * at runtime, so init order relative to WiFi doesn't matter here). */
void ble_gatt_start(void);

/* Notifies the connected BLE central (if any) with a fresh aggregate
 * record, serialized to the docs/DATA_MODEL.md STATS JSON format.
 * No-op if nobody is connected or nobody has subscribed to STATS -
 * NimBLE itself tracks CCCD subscription state and drops the
 * notification silently in that case. Call from main.c's
 * check_aggregation_rollover() right after aggregate_run_hourly()/
 * aggregate_run_daily_rollover() produce a new record. */
void ble_gatt_notify_stats(const aggregate_record_t *rec);
