#include "wl_auto.h"

#include <string.h>

/* One tracked candidate fingerprint: the set of distinct clock-hour buckets
 * it's been seen in that still fall inside the rolling window, plus enough
 * bookkeeping for LRU eviction and one-shot qualification. */
typedef struct {
    bool     used;
    bool     qualified;                  /* already fired, don't fire again */
    uint8_t  fp[FINGERPRINT_HASH_BYTES];
    uint32_t hours[WL_AUTO_MAX_WINDOW];  /* distinct in-window hour buckets */
    uint8_t  num_hours;
    uint32_t last_hour;                  /* newest hour bucket seen (LRU key) */
} candidate_t;

static candidate_t      s_cand[WL_AUTO_MAX_CANDIDATES];
static wl_auto_config_t s_cfg;

static uint8_t clamp_u8(uint8_t v, uint8_t lo, uint8_t hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void wl_auto_init(const wl_auto_config_t *cfg)
{
    memset(s_cand, 0, sizeof(s_cand));
    s_cfg.window_hours = clamp_u8(cfg->window_hours, 1, WL_AUTO_MAX_WINDOW);
    s_cfg.min_distinct_hours =
        clamp_u8(cfg->min_distinct_hours, 1, s_cfg.window_hours);
    s_cfg.max_candidates = cfg->max_candidates;
    if (s_cfg.max_candidates == 0 || s_cfg.max_candidates > WL_AUTO_MAX_CANDIDATES) {
        s_cfg.max_candidates = WL_AUTO_MAX_CANDIDATES;
    }
}

static candidate_t *find(const uint8_t *fp)
{
    for (uint16_t i = 0; i < s_cfg.max_candidates; i++) {
        if (s_cand[i].used &&
            memcmp(s_cand[i].fp, fp, FINGERPRINT_HASH_BYTES) == 0) {
            return &s_cand[i];
        }
    }
    return NULL;
}

/* A slot for a new candidate: a free one if any, else the least-recently-
 * seen (smallest last_hour), reset for reuse. */
static candidate_t *alloc_slot(void)
{
    candidate_t *lru = NULL;
    for (uint16_t i = 0; i < s_cfg.max_candidates; i++) {
        if (!s_cand[i].used) return &s_cand[i];
        if (!lru || s_cand[i].last_hour < lru->last_hour) lru = &s_cand[i];
    }
    return lru;
}

/* Drops stored hour buckets that fell out of the rolling window ending at
 * `now_hour`, compacting in place, and reports whether `now_hour` is
 * already among the remaining buckets. */
static bool prune_and_contains(candidate_t *c, uint32_t now_hour)
{
    uint32_t span = (uint32_t)(s_cfg.window_hours - 1);
    uint32_t window_start = (now_hour >= span) ? now_hour - span : 0;
    bool contains = false;
    uint8_t w = 0;
    for (uint8_t r = 0; r < c->num_hours; r++) {
        if (c->hours[r] < window_start) continue; /* aged out of the window */
        if (c->hours[r] == now_hour) contains = true;
        c->hours[w++] = c->hours[r];
    }
    c->num_hours = w;
    return contains;
}

bool wl_auto_observe(const uint8_t *fp, uint32_t unix_s)
{
    uint32_t hour = unix_s / 3600u;

    candidate_t *c = find(fp);
    if (!c) {
        c = alloc_slot();
        if (!c) return false;
        c->used = true;
        c->qualified = false;
        memcpy(c->fp, fp, FINGERPRINT_HASH_BYTES);
        c->num_hours = 0;
        c->last_hour = hour;
    }

    bool contains = prune_and_contains(c, hour);
    if (!contains && c->num_hours < WL_AUTO_MAX_WINDOW) {
        c->hours[c->num_hours++] = hour;
    }
    if (hour > c->last_hour) c->last_hour = hour;

    if (!c->qualified && c->num_hours >= s_cfg.min_distinct_hours) {
        c->qualified = true;
        return true;
    }
    return false;
}
