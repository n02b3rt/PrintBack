#pragma once

typedef enum {
    UI_STATE_BOOT,
    UI_STATE_IDLE,
    UI_STATE_ARMED,
    UI_STATE_CAPTURED,
    UI_STATE_ERROR,
} ui_state_t;

typedef enum {
    UI_EVENT_LONG_PRESS,
} ui_event_t;

typedef void (*ui_event_cb_t)(ui_event_t ev);

void ui_init(void);
void ui_set_state(ui_state_t st);
void ui_set_event_handler(ui_event_cb_t cb);
