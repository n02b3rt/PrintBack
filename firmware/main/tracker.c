#include "tracker.h"

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#define CAP CONFIG_PRINTBACK_TRACKER_CAPACITY

typedef struct {
    uint8_t  fp[FINGERPRINT_HASH_BYTES];
    int64_t  first_seen_us;
    int64_t  last_seen_us;
    uint32_t hits;
    int8_t   best_rssi;
    bool     used;
} tracker_entry_t;

static tracker_entry_t s_table[CAP];
static tracker_stats_t s_stats;
static SemaphoreHandle_t s_mtx;

static inline uint32_t fp_bucket(const uint8_t *fp)
{
    /* The fingerprint is already a SHA-256 prefix, so the low 32 bits
     * are uniformly distributed, so use them directly as the hash. */
    uint32_t h;
    memcpy(&h, fp, 4);
    return h % CAP;
}

static int find_slot(const uint8_t *fp, bool insert)
{
    uint32_t start = fp_bucket(fp);
    int empty = -1;
    for (uint32_t i = 0; i < CAP; i++) {
        uint32_t idx = (start + i) % CAP;
        if (!s_table[idx].used) {
            if (insert) return (empty >= 0) ? empty : (int)idx;
            return -1;
        }
        if (memcmp(s_table[idx].fp, fp, FINGERPRINT_HASH_BYTES) == 0) {
            return (int)idx;
        }
    }
    return -1;
}

void tracker_init(void)
{
    memset(s_table, 0, sizeof(s_table));
    memset(&s_stats, 0, sizeof(s_stats));
    s_stats.rssi_min = 0;
    s_stats.rssi_max = -127;
    s_mtx = xSemaphoreCreateMutex();
}

bool tracker_observe(const probe_observation_t *obs)
{
    bool fresh = false;
    xSemaphoreTake(s_mtx, portMAX_DELAY);

    int idx = find_slot(obs->fp.hash, true);
    if (idx < 0) {
        /* Table full: evict the oldest entry in the natural probe
         * sequence. Rare at capacity 1024 with a 5-minute window. */
        uint32_t start = fp_bucket(obs->fp.hash);
        int oldest = (int)start;
        for (uint32_t i = 1; i < CAP; i++) {
            uint32_t k = (start + i) % CAP;
            if (s_table[k].last_seen_us < s_table[oldest].last_seen_us) {
                oldest = (int)k;
            }
        }
        idx = oldest;
        s_table[idx].used = false;
        s_stats.evicted++;
    }

    tracker_entry_t *e = &s_table[idx];
    if (!e->used) {
        memcpy(e->fp, obs->fp.hash, FINGERPRINT_HASH_BYTES);
        e->first_seen_us = obs->timestamp_us;
        e->best_rssi     = obs->rssi;
        e->hits          = 0;
        e->used          = true;
        s_stats.unique_devices++;
        fresh = true;
    }
    e->last_seen_us = obs->timestamp_us;
    e->hits++;
    if (obs->rssi > e->best_rssi) e->best_rssi = obs->rssi;

    s_stats.total_observations++;
    if (obs->rssi > s_stats.rssi_max) s_stats.rssi_max = obs->rssi;
    if (obs->rssi < s_stats.rssi_min) s_stats.rssi_min = obs->rssi;

    xSemaphoreGive(s_mtx);
    return fresh;
}

uint32_t tracker_sweep(int64_t now_us, int64_t max_age_us)
{
    uint32_t n = 0;
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    for (uint32_t i = 0; i < CAP; i++) {
        if (s_table[i].used &&
            (now_us - s_table[i].last_seen_us) > max_age_us) {
            s_table[i].used = false;
            s_stats.unique_devices--;
            n++;
        }
    }
    s_stats.evicted += n;
    xSemaphoreGive(s_mtx);
    return n;
}

void tracker_snapshot(tracker_stats_t *out)
{
    xSemaphoreTake(s_mtx, portMAX_DELAY);
    *out = s_stats;
    xSemaphoreGive(s_mtx);
}
