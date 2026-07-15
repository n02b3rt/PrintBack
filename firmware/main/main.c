#include <inttypes.h>
#include <stdatomic.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/usb_serial_jtag.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "wifi_sniffer.h"
#include "fingerprint.h"
#include "tracker.h"
#include "output.h"
#include "whitelist.h"
#include "ui.h"
#include "sd_paths.h"
#include "sd_storage.h"
#include "aggregate.h"
#include "ble_gatt.h"
#include "runtime_config.h"
#include "wl_auto.h"
#include "app_info.h"

static const char *TAG = "printback";

/* Captured once at boot (app_main), served by the BLE STATUS
 * characteristic via app_reset_reason_str(). */
static const char *s_reset_reason = "unknown";

const char *app_reset_reason_str(void)
{
    return s_reset_reason;
}

/* Loads the per-device fingerprint salt from NVS, generating and storing a
 * fresh random one on first boot. Mixed into every fingerprint so the same
 * phone hashes to a different value on each physical unit
 * (fingerprint_set_salt, docs/compliance/README.md). Wiping the SD card
 * alongside a salt change is required: every previously-stored fingerprint
 * stops matching, which is the whole point but also resets returning
 * history. */
static void load_or_create_fingerprint_salt(void)
{
    uint8_t salt[FINGERPRINT_SALT_BYTES];
    size_t len = sizeof(salt);
    bool have = false;

    nvs_handle_t h;
    if (nvs_open("pb_fp", NVS_READWRITE, &h) == ESP_OK) {
        if (nvs_get_blob(h, "salt", salt, &len) == ESP_OK && len == sizeof(salt)) {
            have = true;
        }
        if (!have) {
            esp_fill_random(salt, sizeof(salt));
            nvs_set_blob(h, "salt", salt, sizeof(salt));
            nvs_commit(h);
            ESP_LOGI(TAG, "fingerprint salt: generated a new per-device salt");
        }
        nvs_close(h);
    } else {
        /* No NVS: a session-only random salt still isolates this unit from
         * others, it just won't survive a reboot (fingerprints shift). */
        esp_fill_random(salt, sizeof(salt));
        ESP_LOGW(TAG, "fingerprint salt: NVS unavailable, using a session-only salt");
    }

    fingerprint_set_salt(salt, sizeof(salt));
}

#define LOW_HEAP_WARN_BYTES (20 * 1024)

static const uint8_t HOP_CHANNELS[] = {1, 6, 11};

static const char *reset_reason_str(esp_reset_reason_t r)
{
    switch (r) {
        case ESP_RST_POWERON:  return "poweron";
        case ESP_RST_EXT:      return "ext";
        case ESP_RST_SW:       return "sw";
        case ESP_RST_PANIC:    return "panic";
        case ESP_RST_INT_WDT:  return "int_wdt";
        case ESP_RST_TASK_WDT: return "task_wdt";
        case ESP_RST_WDT:      return "other_wdt";
        case ESP_RST_DEEPSLEEP:return "deepsleep";
        case ESP_RST_BROWNOUT: return "brownout";
        case ESP_RST_SDIO:     return "sdio";
        default:               return "unknown";
    }
}

static _Atomic int64_t s_armed_until_us = 0;

static inline bool is_armed(int64_t now_us)
{
    return atomic_load(&s_armed_until_us) > now_us;
}

static void disarm(void)
{
    atomic_store(&s_armed_until_us, 0);
    ui_set_state(UI_STATE_IDLE);
}

static void on_ui_event(ui_event_t ev)
{
    if (ev == UI_EVENT_SHORT_CLICK) {
        ble_gatt_enter_pairing_mode();
        ui_set_state(UI_STATE_PAIRING);
        ESP_LOGI(TAG, "pairing mode: waiting %ds for a new phone to bond",
                 CONFIG_PRINTBACK_PAIRING_WINDOW_SECONDS);
        return;
    }
    if (ev != UI_EVENT_LONG_PRESS) return;

    int64_t until = esp_timer_get_time() +
                    (int64_t)CONFIG_PRINTBACK_ARMED_TIMEOUT_SECONDS * 1000000;
    atomic_store(&s_armed_until_us, until);
    ui_set_state(UI_STATE_ARMED);
    ESP_LOGI(TAG, "armed: waiting %ds for probe with rssi >= %d dBm",
             CONFIG_PRINTBACK_ARMED_TIMEOUT_SECONDS,
             CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD);
}

static void on_probe(const probe_observation_t *obs)
{
    if (obs->rssi < runtime_config_rssi_floor()) return;

    bool whitelisted = whitelist_contains(obs->fp.hash);

    if (is_armed(obs->timestamp_us)) {
        if (whitelisted) {
            ESP_LOGI(TAG, "armed: fp=%s already on whitelist (rssi=%d)",
                     obs->fp.hex, obs->rssi);
        } else if (obs->rssi < CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD) {
            ESP_LOGI(TAG, "armed: ignored fp=%s rssi=%d (need >= %d)",
                     obs->fp.hex, obs->rssi,
                     CONFIG_PRINTBACK_ARMED_RSSI_THRESHOLD);
        } else if (whitelist_add(obs->fp.hash)) {
            ESP_LOGI(TAG, "captured fp=%s rssi=%d (whitelist now=%u)",
                     obs->fp.hex, obs->rssi, whitelist_count());
            whitelisted = true;
            atomic_store(&s_armed_until_us, 0);
            ui_set_state(UI_STATE_CAPTURED);
        } else {
            ui_set_state(UI_STATE_ERROR);
        }
    }

    /* Auto-whitelist devices that sit here across a shift (staff, router,
     * a neighbour's fridge) rather than passing through like a customer
     * (docs/compliance/README.md "Auto-whitelist"). Only feed non-
     * whitelisted observations; qualification fires once, then whitelist_add
     * excludes it from every future count. */
    if (!whitelisted &&
        wl_auto_observe(obs->fp.hash, sd_storage_current_unix_s())) {
        if (whitelist_add(obs->fp.hash)) {
            whitelisted = true;
            ESP_LOGI(TAG, "auto-whitelist: fp=%s seen across %d+ distinct hours "
                     "and %d+ observations, excluded (whitelist now=%u)",
                     obs->fp.hex, CONFIG_PRINTBACK_AUTO_WL_MIN_DISTINCT_HOURS,
                     CONFIG_PRINTBACK_AUTO_WL_MIN_OBSERVATIONS, whitelist_count());
        }
    }

    bool fresh = tracker_observe(obs);
    output_emit(obs, fresh, whitelisted);
    sd_storage_write_raw(obs, fresh, whitelisted);
}

static void channel_hopper(void *arg)
{
    const TickType_t dwell = pdMS_TO_TICKS(CONFIG_PRINTBACK_HOP_INTERVAL_MS);
    size_t i = 0;
    for (;;) {
        wifi_sniffer_set_channel(HOP_CHANNELS[i]);
        i = (i + 1) % (sizeof(HOP_CHANNELS) / sizeof(HOP_CHANNELS[0]));
        vTaskDelay(dwell);
    }
}

static void usb_link_monitor(void *arg)
{
    /* Polls the USB Serial/JTAG host-connected state and pushes it to the UI
     * so the on-device RGB LED can signal "app is not reading me" at a glance.
     * Detection is SOF-based (host sends Start-of-Frame every 1ms when it has
     * the CDC port open). */
    bool last = false;
    for (;;) {
        bool now = usb_serial_jtag_is_connected();
        if (now != last) {
            ui_set_host_connected(now);
            ESP_LOGI(TAG, "host link: %s", now ? "up" : "down");
            last = now;
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

/* Hour/day the aggregation module last saw. UINT32_MAX/-1 sentinel means
 * "not initialized yet" (first tick after boot has nothing completed to
 * aggregate). */
static uint32_t s_agg_day = UINT32_MAX;
static int      s_agg_hour = -1;

/* Cheap on every housekeeper tick, same pattern as sd_storage's own
 * day-rollover check in Phase 2: compares against the last-seen
 * hour/day and only does real work (aggregate_run_hourly/
 * aggregate_run_daily_rollover) when a boundary was actually crossed. */
static void check_aggregation_rollover(void)
{
    uint32_t now_s = sd_storage_current_unix_s();
    uint32_t day = sd_unix_day_from_unix_s(now_s);
    int hour = sd_hour_from_unix_s(now_s);

    if (s_agg_day == UINT32_MAX) {
        s_agg_day = day;
        s_agg_hour = hour;
        return;
    }
    if (day == s_agg_day && hour == s_agg_hour) return;

    aggregate_record_t rec;
    if (day != s_agg_day) {
        /* last hour of the day that just ended */
        if (aggregate_run_hourly(s_agg_day, 23, &rec)) {
            ble_gatt_notify_stats(&rec);
        }
        if (aggregate_run_daily_rollover(day, &rec)) {
            ble_gatt_notify_stats(&rec);
        }
    } else {
        if (aggregate_run_hourly(s_agg_day, s_agg_hour, &rec)) {
            ble_gatt_notify_stats(&rec);
        }
    }

    /* Once per crossed hour boundary, save the wall clock to NVS so a
     * reboot without a phone keeps roughly-correct dates (9b). Piggybacks
     * on the boundary detection above - no separate timer, ~24 writes/day. */
    sd_storage_persist_wallclock();

    s_agg_day = day;
    s_agg_hour = hour;
}

/* Was pairing mode active as of the last tick? Same "check the transition,
 * not just the level" pattern as s_armed_until_us/is_armed() above -
 * ble_gatt.c owns the actual timeout/bond-success logic, this just
 * mirrors it into the LED. */
static bool s_pairing_ui_active = false;

static void housekeeper(void *arg)
{
    const int64_t window_us =
        (int64_t)CONFIG_PRINTBACK_WINDOW_SECONDS * 1000000;
    const TickType_t period =
        pdMS_TO_TICKS(CONFIG_PRINTBACK_STATS_INTERVAL_SECONDS * 1000);
    for (;;) {
        vTaskDelay(period);
        int64_t now = esp_timer_get_time();
        check_aggregation_rollover();

        if (atomic_load(&s_armed_until_us) > 0 && !is_armed(now)) {
            disarm();
            ESP_LOGI(TAG, "armed window expired");
        }

        bool pairing_now = ble_gatt_pairing_mode_active();
        if (s_pairing_ui_active && !pairing_now) {
            ui_set_state(UI_STATE_IDLE);
            ESP_LOGI(TAG, "pairing window closed");
        }
        s_pairing_ui_active = pairing_now;

        uint32_t evicted = tracker_sweep(now, window_us);
        tracker_stats_t s;
        tracker_snapshot(&s);
        uint32_t free_heap = esp_get_free_heap_size();
        uint32_t min_heap  = esp_get_minimum_free_heap_size();
        ESP_LOGI(TAG,
                 "active=%" PRIu32 " obs=%" PRIu32 " evicted=%" PRIu32
                 " wl=%u rssi=[%d,%d] heap=%" PRIu32 " min_heap=%" PRIu32
                 " sd_bytes=%" PRIu32 " dropped=%" PRIu32,
                 s.unique_devices, s.total_observations, evicted,
                 whitelist_count(), s.rssi_min, s.rssi_max,
                 free_heap, min_heap, sd_storage_raw_bytes_written(),
                 wifi_sniffer_dropped_count());
        if (free_heap < LOW_HEAP_WARN_BYTES) {
            ESP_LOGW(TAG, "low free heap: %" PRIu32 " bytes, leak suspected",
                     free_heap);
        }
    }
}

void app_main(void)
{
    esp_reset_reason_t reason = esp_reset_reason();
    s_reset_reason = reset_reason_str(reason);
    ESP_LOGI(TAG, "boot: reset_reason=%s (%d) free_heap=%" PRIu32,
             s_reset_reason, (int)reason, esp_get_free_heap_size());

    /* Initialize NVS first: whitelist_init(), runtime_config_init() and
     * sd_storage_init() below all read persisted state, and NimBLE's bond
     * store uses NVS too. It used to be initialized inside
     * wifi_sniffer_start(), which runs after those readers - so their
     * boot-time nvs_open() silently failed and persisted values were only
     * ever reloaded after the next write, not at boot. Bare
     * nvs_flash_init() (no erase-on-mismatch) on purpose: a version/space
     * problem should fail loudly, never silently wipe the bond store. */
    ESP_ERROR_CHECK(nvs_flash_init());
    load_or_create_fingerprint_salt(); /* before any probe is hashed */

    whitelist_init();
    wl_auto_init(&(wl_auto_config_t){
        .window_hours       = CONFIG_PRINTBACK_AUTO_WL_WINDOW_HOURS,
        .min_distinct_hours = CONFIG_PRINTBACK_AUTO_WL_MIN_DISTINCT_HOURS,
        .min_observations   = CONFIG_PRINTBACK_AUTO_WL_MIN_OBSERVATIONS,
        .max_candidates     = CONFIG_PRINTBACK_AUTO_WL_MAX_CANDIDATES,
    });
    tracker_init();
    runtime_config_init(); /* before wifi_sniffer_start(): on_probe() needs the RSSI floor from the first packet */
    ui_init();
    ui_set_event_handler(on_ui_event);
    sd_storage_init(); /* logs its own error and keeps going without SD if this fails */
    wifi_sniffer_start(on_probe);
    ble_gatt_start(); /* runs its own NimBLE host task internally, no xTaskCreate here */
    xTaskCreate(channel_hopper,   "hop",     2048, NULL, 4, NULL);
    xTaskCreate(housekeeper,      "house",   3072, NULL, 3, NULL);
    xTaskCreate(usb_link_monitor, "usb_mon", 2048, NULL, 2, NULL);
}
