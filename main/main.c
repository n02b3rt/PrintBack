#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "sdkconfig.h"

#include "wifi_sniffer.h"
#include "tracker.h"
#include "output.h"

static const char *TAG = "printback";

static const uint8_t HOP_CHANNELS[] = {1, 6, 11};

static void on_probe(const probe_observation_t *obs)
{
    if (obs->rssi < CONFIG_PRINTBACK_RSSI_FLOOR) return;
    bool fresh = tracker_observe(obs);
    output_emit(obs, fresh);
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

static void housekeeper(void *arg)
{
    const int64_t window_us = (int64_t)CONFIG_PRINTBACK_WINDOW_SECONDS * 1000000;
    const TickType_t period = pdMS_TO_TICKS(CONFIG_PRINTBACK_STATS_INTERVAL_SECONDS * 1000);
    for (;;) {
        vTaskDelay(period);
        uint32_t evicted = tracker_sweep(esp_timer_get_time(), window_us);
        tracker_stats_t s;
        tracker_snapshot(&s);
        ESP_LOGI(TAG,
                 "active=%" PRIu32 " obs=%" PRIu32 " evicted=%" PRIu32
                 " rssi=[%d,%d]",
                 s.unique_devices, s.total_observations, evicted,
                 s.rssi_min, s.rssi_max);
    }
}

void app_main(void)
{
    tracker_init();
    wifi_sniffer_start(on_probe);
    xTaskCreate(channel_hopper, "hop",   2048, NULL, 4, NULL);
    xTaskCreate(housekeeper,    "house", 3072, NULL, 3, NULL);
}
