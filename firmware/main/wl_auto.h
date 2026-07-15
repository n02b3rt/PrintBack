#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "fingerprint.h"

/* Pure, host-testable auto-whitelist accumulator (docs/compliance/README.md
 * "Auto-whitelist"). Fed the stream of (fingerprint, unix_s) observations,
 * it flags a fingerprint seen in >= min_distinct_hours distinct clock-hours
 * within a rolling window_hours window - i.e. something sitting on the
 * premises across most of a shift (staff phone, the router, a neighbour's
 * fridge), not a passing customer. No ESP/FreeRTOS/NVS dependencies on
 * purpose: firmware/test_host/test_wl_auto.c exercises it with plain gcc. */

typedef struct {
    uint8_t  window_hours;        /* rolling window length, in clock-hours */
    uint8_t  min_distinct_hours;  /* qualify at >= this many distinct hours */
    uint16_t min_observations;    /* AND at >= this many total observations
                                   * (0 = gate disabled). Distinguishes a
                                   * device that actually sits here generating
                                   * traffic from one merely glimpsed once in
                                   * each of several hours. */
    uint16_t max_candidates;      /* LRU cap on simultaneously tracked fp */
} wl_auto_config_t;

/* Compile-time upper bounds for the static state; a runtime config is
 * clamped into these. */
#define WL_AUTO_MAX_CANDIDATES 256
#define WL_AUTO_MAX_WINDOW     24

/* (Re)initializes the accumulator, clearing all tracked state. Config
 * values are clamped to the WL_AUTO_MAX_* bounds and to
 * min_distinct_hours <= window_hours. */
void wl_auto_init(const wl_auto_config_t *cfg);

/* Feeds one observation. Returns true exactly once per fingerprint: on the
 * observation that first satisfies BOTH gates - >= min_distinct_hours
 * distinct in-window hours AND >= min_observations total observations.
 * Returns false otherwise, including every later observation of an
 * already-qualified fingerprint. Designed for time-ordered (monotonic
 * unix_s) input, as real capture produces. */
bool wl_auto_observe(const uint8_t *fp, uint32_t unix_s);
