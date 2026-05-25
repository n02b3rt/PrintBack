#include "whitelist.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "esp_log.h"

#define NS  "printback"
#define KEY "wl"

static const char *TAG = "wl";

static uint8_t          s_entries[WHITELIST_MAX][FINGERPRINT_HASH_BYTES];
static uint16_t         s_count;
static SemaphoreHandle_t s_mtx;

static int find_locked(const uint8_t *fp)
{
    for (uint16_t i = 0; i < s_count; i++) {
        if (memcmp(s_entries[i], fp, FINGERPRINT_HASH_BYTES) == 0) return i;
    }
    return -1;
}

static void persist_locked(void)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, KEY, s_entries, (size_t)s_count * FINGERPRINT_HASH_BYTES);
    nvs_commit(h);
    nvs_close(h);
}

void whitelist_init(void)
{
    s_mtx = xSemaphoreCreateMutex();

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "no stored whitelist");
        return;
    }
    size_t len = sizeof(s_entries);
    if (nvs_get_blob(h, KEY, s_entries, &len) == ESP_OK) {
        s_count = (uint16_t)(len / FINGERPRINT_HASH_BYTES);
        ESP_LOGI(TAG, "loaded %u entries", s_count);
    }
    nvs_close(h);
}

bool whitelist_contains(const uint8_t *fp)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    bool ok = find_locked(fp) >= 0;
    xSemaphoreGive(s_mtx);
    return ok;
}

bool whitelist_add(const uint8_t *fp)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    bool ok = false;
    if (find_locked(fp) < 0 && s_count < WHITELIST_MAX) {
        memcpy(s_entries[s_count++], fp, FINGERPRINT_HASH_BYTES);
        persist_locked();
        ok = true;
    }
    xSemaphoreGive(s_mtx);
    return ok;
}

bool whitelist_remove(const uint8_t *fp)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    bool ok = false;
    int idx = find_locked(fp);
    if (idx >= 0) {
        if (idx != s_count - 1) {
            memcpy(s_entries[idx], s_entries[s_count - 1],
                   FINGERPRINT_HASH_BYTES);
        }
        s_count--;
        persist_locked();
        ok = true;
    }
    xSemaphoreGive(s_mtx);
    return ok;
}

void whitelist_clear(void)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    s_count = 0;
    persist_locked();
    xSemaphoreGive(s_mtx);
}

uint16_t whitelist_count(void)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    uint16_t c = s_count;
    xSemaphoreGive(s_mtx);
    return c;
}
