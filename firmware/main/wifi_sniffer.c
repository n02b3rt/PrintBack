#include "wifi_sniffer.h"

#include <string.h>
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

static const char *TAG = "sniffer";

#define PROBE_REQ_SUBTYPE 0x04
#define MGMT_HDR_LEN      24  /* FC(2) + Dur(2) + DA(6) + SA(6) + BSSID(6) + Seq(2) */

/* Generous relative to real probe-request bursts (a handful of devices
 * probing within one channel-hop interval) - sized to absorb a burst
 * while the consumer task is mid-way through one slower-than-usual I/O
 * operation, not to paper over a sustained backlog. */
#define PROBE_QUEUE_LEN 32

static probe_cb_t s_cb = NULL;
static QueueHandle_t s_probe_queue;
static volatile uint32_t s_dropped_count = 0;

/* cb (main.c's on_probe -> whitelist/tracker/output/SD) can legitimately
 * block for a while - SD writes include an explicit fflush()+fsync()
 * (docs/LEARNINGS.md 2026-07-08), and USB-CDC printf() can back up with
 * nothing draining it if the device runs standalone with no host
 * reading. Running cb directly from on_packet() below would mean that
 * blocking happens on the WiFi driver's OWN promiscuous-callback
 * context, which ESP-IDF documents as time-critical - do lengthy work
 * there and packet capture itself degrades, which reproduces exactly as
 * "sniffing silently stops after a few hours, a power cycle fixes it"
 * (docs/LEARNINGS.md 2026-07-11). This task is the decoupling point: it
 * owns the only call to cb, entirely off the driver's callback path, so
 * however slow SD/USB I/O gets, it can never stall capture - at worst
 * the queue backs up and older-than-drained observations get dropped
 * (s_dropped_count), never a stall.
 */
static void probe_proc_task(void *arg)
{
    (void)arg;
    probe_observation_t obs;
    for (;;) {
        if (xQueueReceive(s_probe_queue, &obs, portMAX_DELAY) == pdTRUE && s_cb) {
            s_cb(&obs);
        }
    }
}

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
    if (fingerprint_from_ies(ies, ie_len, &obs.fp) != 0) return;

    /* Zero timeout: this still runs on the WiFi driver's own callback
     * context, so blocking here to wait for queue space would defeat
     * the entire point - drop and count instead. */
    if (xQueueSend(s_probe_queue, &obs, 0) != pdTRUE) {
        s_dropped_count++;
    }
}

uint32_t wifi_sniffer_dropped_count(void)
{
    return s_dropped_count;
}

void wifi_sniffer_set_channel(uint8_t channel)
{
    esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
}

void wifi_sniffer_start(probe_cb_t cb)
{
    s_cb = cb;

    /* Must exist before promiscuous mode goes live below - on_packet()
     * can start firing as soon as esp_wifi_set_promiscuous(true) returns. */
    s_probe_queue = xQueueCreate(PROBE_QUEUE_LEN, sizeof(probe_observation_t));
    xTaskCreate(probe_proc_task, "probe_proc", 4096, NULL, 3, NULL);

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
