#pragma once

#include <stdbool.h>

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

/* Opens the pairing window (docs/DECISIONS.md D5, docs/TASKS.md Phase 5):
 * temporarily accepts connections from ANY device (normally only
 * already-bonded peers can connect at all, see gatt_advertise() in
 * ble_gatt.c), for CONFIG_PRINTBACK_PAIRING_WINDOW_SECONDS or until a new
 * bond completes, whichever comes first. Call from main.c's
 * on_ui_event() on UI_EVENT_SHORT_CLICK. No-op if already in pairing
 * mode (a second click during an open window doesn't restart the
 * timer). */
void ble_gatt_enter_pairing_mode(void);

/* True while the pairing window opened by ble_gatt_enter_pairing_mode()
 * is still open. main.c's housekeeper polls this (same pattern as the
 * existing armed-window check) to know when to revert the LED to IDLE. */
bool ble_gatt_pairing_mode_active(void);
