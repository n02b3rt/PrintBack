#include "runtime_config.h"

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "aggregate.h"
#include "runtime_config_parse.h"

#define NS       "printback"
#define KEY_RSSI "rssi_floor"
#define KEY_DAYS "ret_days"

static const char *TAG = "runtime_cfg";

/* Plain volatile, not mutex-guarded: each field is read independently by
 * its own call site (on_probe()'s RSSI filter, aggregate.c's history
 * rebuild), never as a combined multi-field snapshot, so there's no
 * tearing hazard to guard against - same reasoning as ui.c's s_state. */
static volatile int8_t  s_rssi_floor = CONFIG_PRINTBACK_RSSI_FLOOR;
static volatile uint8_t s_returning_window_days = RETURNING_WINDOW_DAYS;

static void persist(void)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_i8(h, KEY_RSSI, s_rssi_floor);
    nvs_set_u8(h, KEY_DAYS, s_returning_window_days);
    nvs_commit(h);
    nvs_close(h);
}

void runtime_config_init(void)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "no stored config, using compile-time defaults "
                 "(rssi_floor=%d returning_window_days=%u)",
                 s_rssi_floor, s_returning_window_days);
        return;
    }

    int8_t rssi;
    uint8_t days;
    bool have_rssi = nvs_get_i8(h, KEY_RSSI, &rssi) == ESP_OK;
    bool have_days = nvs_get_u8(h, KEY_DAYS, &days) == ESP_OK;
    nvs_close(h);

    if (have_rssi) s_rssi_floor = rssi;
    if (have_days) s_returning_window_days = days;

    if (have_rssi || have_days) {
        ESP_LOGI(TAG, "loaded from NVS: rssi_floor=%d returning_window_days=%u",
                 s_rssi_floor, s_returning_window_days);
    }
}

int8_t runtime_config_rssi_floor(void)
{
    return s_rssi_floor;
}

uint8_t runtime_config_returning_window_days(void)
{
    return s_returning_window_days;
}

bool runtime_config_apply_json(const char *json, size_t len)
{
    int rssi, days;
    if (!runtime_config_extract_json(json, len, &rssi, &days)) return false;
    if (!runtime_config_validate(rssi, days)) return false;

    s_rssi_floor = (int8_t)rssi;
    s_returning_window_days = (uint8_t)days;
    persist();

    ESP_LOGI(TAG, "config updated via BLE: rssi_floor=%d returning_window_days=%u",
             rssi, days);
    return true;
}
