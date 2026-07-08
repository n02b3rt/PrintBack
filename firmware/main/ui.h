#pragma once

#include <stdbool.h>

typedef enum {
    UI_STATE_BOOT,
    UI_STATE_IDLE,
    UI_STATE_ARMED,
    UI_STATE_CAPTURED,
    UI_STATE_ERROR,
    UI_STATE_PAIRING,
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

/* Overlay: when state is IDLE, this flag picks between the normal white
 * pulse (host is reading us) and a slow blue blink (no host, firmware OK
 * but the desktop app isn't listening). Higher-priority states (ARMED,
 * CAPTURED, ERROR) ignore this flag. */
void ui_set_host_connected(bool connected);
