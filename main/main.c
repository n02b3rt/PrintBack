#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "wifi_sniffer.h"

static const char *TAG = "printback";

static const uint8_t HOP_CHANNELS[] = {1, 6, 11};
static const TickType_t HOP_INTERVAL = pdMS_TO_TICKS(400);

static void on_probe(const probe_observation_t *obs)
{
    ESP_LOGI(TAG,
             "fp=%s mac=%02x:%02x:%02x:%02x:%02x:%02x rssi=%d ch=%u ies=%u",
             obs->fp.hex,
             obs->src_mac[0], obs->src_mac[1], obs->src_mac[2],
             obs->src_mac[3], obs->src_mac[4], obs->src_mac[5],
             obs->rssi, obs->channel, obs->fp.ie_count);
}

static void channel_hopper(void *arg)
{
    size_t i = 0;
    for (;;) {
        wifi_sniffer_set_channel(HOP_CHANNELS[i]);
        i = (i + 1) % (sizeof(HOP_CHANNELS) / sizeof(HOP_CHANNELS[0]));
        vTaskDelay(HOP_INTERVAL);
    }
}

void app_main(void)
{
    wifi_sniffer_start(on_probe);
    xTaskCreate(channel_hopper, "hop", 2048, NULL, 4, NULL);
}
