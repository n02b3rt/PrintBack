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

/* cb runs on a dedicated consumer task, never on the WiFi driver's own
 * promiscuous-callback context - see wifi_sniffer.c for why (blocking
 * I/O in cb, e.g. SD writes or USB-CDC printf, must never be able to
 * stall packet capture itself). */
void wifi_sniffer_start(probe_cb_t cb);
void wifi_sniffer_set_channel(uint8_t channel);

/* Observations dropped because the internal queue between the
 * promiscuous callback and cb's consumer task was full - cb (SD/USB I/O)
 * fell behind capture. Should be ~0 in normal operation; a persistently
 * climbing count means cb is taking too long per observation. Exposed so
 * main.c's housekeeper() can log it alongside the other operational
 * stats (docs/LEARNINGS.md 2026-07-11 WiFi-stall investigation). */
uint32_t wifi_sniffer_dropped_count(void);
