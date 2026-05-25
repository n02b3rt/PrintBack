#pragma once

#include <stdint.h>
#include "fingerprint.h"

typedef struct {
    int64_t       timestamp_us;
    uint8_t       src_mac[6];
    int8_t        rssi;
    uint8_t       channel;
    fingerprint_t fp;
} probe_observation_t;

typedef void (*probe_cb_t)(const probe_observation_t *obs);

void wifi_sniffer_start(probe_cb_t cb);
void wifi_sniffer_set_channel(uint8_t channel);
