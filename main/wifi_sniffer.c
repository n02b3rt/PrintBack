#include "wifi_sniffer.h"

#include <string.h>
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"

static const char *TAG = "sniffer";

#define PROBE_REQ_SUBTYPE 0x04
#define MGMT_HDR_LEN      24  /* FC(2) + Dur(2) + DA(6) + SA(6) + BSSID(6) + Seq(2) */

static probe_cb_t s_cb = NULL;

static void on_packet(void *buf, wifi_promiscuous_pkt_type_t type)
{
    if (type != WIFI_PKT_MGMT || !s_cb) return;

    const wifi_promiscuous_pkt_t *pkt = (const wifi_promiscuous_pkt_t *)buf;
    const uint8_t *payload = pkt->payload;
    uint16_t len = pkt->rx_ctrl.sig_len;
    if (len < MGMT_HDR_LEN) return;

    uint8_t fc0 = payload[0];
    uint8_t subtype = (fc0 >> 4) & 0x0f;
    if (subtype != PROBE_REQ_SUBTYPE) return;

    probe_observation_t obs = {
        .timestamp_us = esp_timer_get_time(),
        .rssi         = pkt->rx_ctrl.rssi,
        .channel      = pkt->rx_ctrl.channel,
    };
    memcpy(obs.src_mac, &payload[10], 6);

    const uint8_t *ies = payload + MGMT_HDR_LEN;
    size_t ie_len = len - MGMT_HDR_LEN - 4; /* trim FCS */
    if (fingerprint_from_ies(ies, ie_len, &obs.fp) == 0) {
        s_cb(&obs);
    }
}

void wifi_sniffer_set_channel(uint8_t channel)
{
    esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
}

void wifi_sniffer_start(probe_cb_t cb)
{
    s_cb = cb;

    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_NULL));
    ESP_ERROR_CHECK(esp_wifi_start());

    wifi_promiscuous_filter_t filter = { .filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT };
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous_filter(&filter));
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous_rx_cb(on_packet));
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous(true));
    ESP_ERROR_CHECK(esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE));

    ESP_LOGI(TAG, "promiscuous mode active");
}
