#include <inttypes.h>
#include <stdatomic.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/usb_serial_jtag.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "sdkconfig.h"

#include "wifi_sniffer.h"
#include "tracker.h"
#include "output.h"
#include "whitelist.h"
#include "ui.h"
#include "sd_storage.h"

static const char *TAG = "printback";

#define LOW_HEAP_WARN_BYTES (20 * 1024)

static const uint8_t HOP_CHANNELS[] = {1, 6, 11};

static const char *reset_reason_str(esp_reset_reason_t r)
{
    switch (r) {
        case ESP_RST_POWERON:  return "poweron";
        case ESP_RST_EXT:      return "ext";
        case ESP_RST_SW:       return "sw";
        case ESP_RST_PANIC:    return "panic";
        case ESP_RST_INT_WDT:  return "int_wdt";
        case ESP_RST_TASK_WDT: return "task_wdt";
        case ESP_RST_WDT:      return "other_wdt";
        case ESP_RST_DEEPSLEEP:return "deepsleep";
        case ESP_RST_BROWNOUT: return "brownout";
        case ESP_RST_SDIO:     return "sdio";
        default:               return "unknown";
    }
}

static _Atomic int64_t s_armed_until_us = 0;

static inline bool is_armed(int64_t now_us)
{
    return atomic_load(&s_armed_until_us) > now_us;
}

static void disarm(void)
{
    atomic_store(&s_armed_until_us, 0);
    ui_set_state(UI_STATE_IDLE);
}

static void on_ui_event(ui_event_t ev)
{
    if (ev != UI_EVENT_LONG_PRESS) return;
    int64_t until = esp_timer_get_time() +
                    (int64_t)CONFIG_PRINTBACK_ARMED_TIMEOUT_SECONDS * 1000000;
    atomic_store(&s_armed_until_us, until);
    ui_set_state(UI_STATE_ARMED);
    ESP_LOGI(TAG, "armed: waiting %ds for probe with rssi >= %d dBm",
             CONFIG_PRINTBACK_ARMED_TIMEOUT_SECONDS,
             CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD);
}

static void on_probe(const probe_observation_t *obs)
{
    if (obs->rssi < CONFIG_PRINTBACK_RSSI_FLOOR) return;

    bool whitelisted = whitelist_contains(obs->fp.hash);

    if (is_armed(obs->timestamp_us)) {
        if (whitelisted) {
            ESP_LOGI(TAG, "armed: fp=%s already on whitelist (rssi=%d)",
                     obs->fp.hex, obs->rssi);
        } else if (obs->rssi < CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD) {
            ESP_LOGI(TAG, "armed: ignored fp=%s rssi=%d (need >= %d)",
                     obs->fp.hex, obs->rssi,
                     CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD);
        } else if (whitelist_add(obs->fp.hash)) {
            ESP_LOGI(TAG, "captured fp=%s rssi=%d (whitelist now=%u)",
                     obs->fp.hex, obs->rssi, whitelist_count());
            whitelisted = true;
            atomic_store(&s_armed_until_us, 0);
            ui_set_state(UI_STATE_CAPTURED);
        } else {
            ui_set_state(UI_STATE_ERROR);
        }
    }

    bool fresh = tracker_observe(obs);
    output_emit(obs, fresh, whitelisted);
    sd_storage_write_raw(obs, fresh, whitelisted);
}

static void channel_hopper(void *arg)
{
    const TickType_t dwell = pdMS_TO_TICKS(CONFIG_PRINTBACK_HOP_INTERVAL_MS);
    size_t i = 0;
    for (;;) {
        wifi_sniffer_set_channel(HOP_CHANNELS[i]);
        i = (i + 1) % (sizeof(HOP_CHANNELS) / sizeof(HOP_CHANNELS[0]));
        vTaskDelay(dwell);
    }
}

static void usb_link_monitor(void *arg)
{
    /* Polls the USB Serial/JTAG host-connected state and pushes it to the UI
     * so the on-device RGB LED can signal "app is not reading me" at a glance.
     * Detection is SOF-based (host sends Start-of-Frame every 1ms when it has
     * the CDC port open). */
    bool last = false;
    for (;;) {
        bool now = usb_serial_jtag_is_connected();
        if (now != last) {
            ui_set_host_connected(now);
            ESP_LOGI(TAG, "host link: %s", now ? "up" : "down");
            last = now;
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void housekeeper(void *arg)
{
    const int64_t window_us =
        (int64_t)CONFIG_PRINTBACK_WINDOW_SECONDS * 1000000;
    const TickType_t period =
        pdMS_TO_TICKS(CONFIG_PRINTBACK_STATS_INTERVAL_SECONDS * 1000);
    for (;;) {
        vTaskDelay(period);
        int64_t now = esp_timer_get_time();

        if (atomic_load(&s_armed_until_us) > 0 && !is_armed(now)) {
            disarm();
            ESP_LOGI(TAG, "armed window expired");
        }

        uint32_t evicted = tracker_sweep(now, window_us);
        tracker_stats_t s;
        tracker_snapshot(&s);
        uint32_t free_heap = esp_get_free_heap_size();
        uint32_t min_heap  = esp_get_minimum_free_heap_size();
        ESP_LOGI(TAG,
                 "active=%" PRIu32 " obs=%" PRIu32 " evicted=%" PRIu32
                 " wl=%u rssi=[%d,%d] heap=%" PRIu32 " min_heap=%" PRIu32,
                 s.unique_devices, s.total_observations, evicted,
                 whitelist_count(), s.rssi_min, s.rssi_max,
                 free_heap, min_heap);
        if (free_heap < LOW_HEAP_WARN_BYTES) {
            ESP_LOGW(TAG, "low free heap: %" PRIu32 " bytes, leak suspected",
                     free_heap);
        }
    }
}

void app_main(void)
{
    esp_reset_reason_t reason = esp_reset_reason();
    ESP_LOGI(TAG, "boot: reset_reason=%s (%d) free_heap=%" PRIu32,
             reset_reason_str(reason), (int)reason, esp_get_free_heap_size());

    whitelist_init();
    tracker_init();
    ui_init();
    ui_set_event_handler(on_ui_event);
    sd_storage_init(); /* logs its own error and keeps going without SD if this fails */
    wifi_sniffer_start(on_probe);
    xTaskCreate(channel_hopper,   "hop",     2048, NULL, 4, NULL);
    xTaskCreate(housekeeper,      "house",   3072, NULL, 3, NULL);
    xTaskCreate(usb_link_monitor, "usb_mon", 2048, NULL, 2, NULL);
}
