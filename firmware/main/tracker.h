#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "wifi_sniffer.h"

typedef struct {
    uint32_t unique_devices;
    uint32_t total_observations;
    uint32_t evicted;
    int8_t   rssi_min;
    int8_t   rssi_max;
} tracker_stats_t;

void tracker_init(void);

/* Record an observation. Returns true when the fingerprint is seen for
 * the first time inside the active window. */
bool tracker_observe(const probe_observation_t *obs);

/* Evict entries whose last_seen is older than `now_us - max_age_us`.
 * Returns the number of evicted slots. */
uint32_t tracker_sweep(int64_t now_us, int64_t max_age_us);

void tracker_snapshot(tracker_stats_t *out);
