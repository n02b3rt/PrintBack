#pragma once

/* Human-readable reason for the last reset (poweron/panic/brownout/...),
 * captured once at boot in app_main() from esp_reset_reason(). Exposed so
 * the BLE STATUS characteristic (ble_gatt.c) can report it to a phone
 * without a serial console attached. */
const char *app_reset_reason_str(void);
