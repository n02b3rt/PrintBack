#pragma once

#include <stdbool.h>

typedef enum {
    UI_STATE_BOOT,
    UI_STATE_IDLE,
    UI_STATE_ARMED,
    UI_STATE_CAPTURED,
    UI_STATE_ERROR,
    UI_STATE_PAIRING,
    /* A phone is pulling a BLE SYNC backlog replay (ble_gatt.c's
     * sync_tick_cb()) - a smooth breathing blue pulse, distinct from
     * PAIRING's hard cyan blink, so "actively sending data" reads
     * differently at a glance from "waiting for a button/bond". */
    UI_STATE_SYNCING,
} ui_state_t;

typedef enum {
    UI_EVENT_LONG_PRESS,
    /* Quick press-release, shorter than the long-press threshold (Phase 5:
     * enters BLE pairing mode, docs/DECISIONS.md D5). Debounced against
     * noise but otherwise purely additive - the existing long-press path
     * (whitelist arm) is unchanged. */
    UI_EVENT_SHORT_CLICK,
} ui_event_t;

typedef void (*ui_event_cb_t)(ui_event_t ev);

void ui_init(void);
void ui_set_state(ui_state_t st);
void ui_set_event_handler(ui_event_cb_t cb);

/* True if the button was held from boot long enough to arm a BLE bond
 * wipe (the factory-reset gesture, see ui.c check_boot_bond_reset()).
 * ble_gatt.c reads this in gatt_on_sync() and, if set, clears the bond
 * store before restoring the connection whitelist. Latched at boot, so
 * safe to read once the host has synced. */
bool ui_boot_reset_requested(void);

/* Overlay: when state is IDLE, this flag picks between the normal white
 * pulse (host is reading us) and a slow blue blink (no host, firmware OK
 * but the desktop app isn't listening). Higher-priority states (ARMED,
 * CAPTURED, ERROR) ignore this flag. */
void ui_set_host_connected(bool connected);
