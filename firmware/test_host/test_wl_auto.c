#include <stdio.h>
#include <string.h>
#include "wl_auto.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

/* Distinct 8-byte fingerprints for the scenarios below. */
static const uint8_t FP_WORKER[FINGERPRINT_HASH_BYTES]   = {1,1,1,1,1,1,1,1};
static const uint8_t FP_CUSTOMER[FINGERPRINT_HASH_BYTES] = {2,2,2,2,2,2,2,2};
static const uint8_t FP_FRIDGE[FINGERPRINT_HASH_BYTES]   = {3,3,3,3,3,3,3,3};

/* Feeds one observation at a given absolute hour (a few probes within the
 * hour, to mimic real capture - the accumulator must dedup them to one
 * distinct hour). Returns true if the fp qualified on any of them. */
static bool observe_hour(const uint8_t *fp, uint32_t hour)
{
    bool fired = false;
    for (int i = 0; i < 3; i++) {
        if (wl_auto_observe(fp, hour * 3600u + i * 60u)) fired = true;
    }
    return fired;
}

int main(void)
{
    wl_auto_config_t cfg = {
        .window_hours = 8,
        .min_distinct_hours = 6,
        .max_candidates = 64,
    };
    wl_auto_init(&cfg);

    /* Staff phone: present every hour across a shift. Must NOT qualify
     * before the 6th distinct hour, and must qualify exactly on it. */
    bool fired = false;
    for (uint32_t h = 100; h <= 104; h++) fired |= observe_hour(FP_WORKER, h);
    CHECK(fired == false, "worker: not qualified after only 5 distinct hours");
    bool fired6 = observe_hour(FP_WORKER, 105);
    CHECK(fired6 == true, "worker: qualifies on the 6th distinct hour");
    /* Qualification is one-shot: later hours don't fire again. */
    bool fired_again = observe_hour(FP_WORKER, 106);
    CHECK(fired_again == false, "worker: does not re-fire once qualified");

    /* Customer popping in twice a day, hours far apart: never 6 distinct
     * hours inside any 8-hour window, so never auto-whitelisted. */
    wl_auto_init(&cfg);
    bool cust_fired = false;
    for (int day = 0; day < 5; day++) {
        uint32_t base = 200u + (uint32_t)day * 24u;
        cust_fired |= observe_hour(FP_CUSTOMER, base + 9);   /* morning */
        cust_fired |= observe_hour(FP_CUSTOMER, base + 18);  /* evening */
    }
    CHECK(cust_fired == false, "customer 2x/day: never qualifies");

    /* Neighbour's fridge/AP: present continuously for 24 hours. Correctly
     * qualifies (it isn't a customer either) - fires once, around hour 6. */
    wl_auto_init(&cfg);
    int fridge_fire_count = 0;
    for (uint32_t h = 300; h < 324; h++) {
        if (observe_hour(FP_FRIDGE, h)) fridge_fire_count++;
    }
    CHECK(fridge_fire_count == 1, "fridge 24h: qualifies exactly once");

    /* Rolling window really rolls: a gap longer than the window resets the
     * distinct-hour count, so 5 hours + big gap + 5 hours never reaches 6
     * within one window. */
    wl_auto_init(&cfg);
    bool rolled = false;
    for (uint32_t h = 400; h <= 404; h++) rolled |= observe_hour(FP_WORKER, h);
    for (uint32_t h = 500; h <= 504; h++) rolled |= observe_hour(FP_WORKER, h);
    CHECK(rolled == false, "rolling window: 5h + gap + 5h stays under threshold");

    /* LRU eviction: with a tiny cap, a fingerprint pushed out loses its
     * accumulated hours and has to start over. */
    wl_auto_config_t small = { .window_hours = 8, .min_distinct_hours = 6, .max_candidates = 2 };
    wl_auto_init(&small);
    const uint8_t A[FINGERPRINT_HASH_BYTES] = {0xA,0,0,0,0,0,0,0};
    const uint8_t B[FINGERPRINT_HASH_BYTES] = {0xB,0,0,0,0,0,0,0};
    const uint8_t C[FINGERPRINT_HASH_BYTES] = {0xC,0,0,0,0,0,0,0};
    observe_hour(A, 10);            /* A: 1 hour */
    observe_hour(B, 11);            /* B: 1 hour, slots now full (A,B) */
    observe_hour(C, 12);            /* C evicts A (LRU) */
    /* A comes back but its history is gone; one hour only, no qualify. */
    bool a_back = observe_hour(A, 13);
    CHECK(a_back == false, "lru: evicted fingerprint restarts from zero");

    if (failures) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
