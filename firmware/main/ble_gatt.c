#include "ble_gatt.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "sdkconfig.h"

#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/ble_store.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"

#include "aggregate.h"
#include "runtime_config.h"
#include "sd_storage.h"

static const char *TAG = "ble_gatt";

#define DEVICE_NAME "PrintBack"

/* Max simultaneously bonded phones the controller whitelist tracks.
 * Not a hard product requirement, just a sane static buffer size - NVS/
 * controller limits would bind first in practice. */
#define MAX_BONDED_PEERS 8

/* Preferred ATT MTU: a single STATS JSON row (~70-90B) needs more than
 * the unnegotiated default of 23B. Every BLE 4.2+ central negotiates at
 * least this much in practice (docs/DATA_MODEL.md "Chunking"); the very
 * low MTU fallback (fragment envelope) is deliberately out of scope for
 * Phase 4, see docs/PROGRESS.md. */
#define PREFERRED_MTU 247

#define STATS_JSON_MAX_LEN 96
#define CONFIG_JSON_MAX_LEN 64

/* e794a7d8-6905-4552-b7a2-d0cdc9dae0f6 (docs/DATA_MODEL.md) */
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0xf6, 0xe0, 0xda, 0xc9, 0xcd, 0xd0, 0xa2, 0xb7,
                      0x52, 0x45, 0x05, 0x69, 0xd8, 0xa7, 0x94, 0xe7);

/* 1b1465c2-296e-4acd-b544-ba1a30ed7f13 (docs/DATA_MODEL.md), read + notify */
static const ble_uuid128_t s_stats_chr_uuid =
    BLE_UUID128_INIT(0x13, 0x7f, 0xed, 0x30, 0x1a, 0xba, 0x44, 0xb5,
                      0xcd, 0x4a, 0x6e, 0x29, 0xc2, 0x65, 0x14, 0x1b);

/* c5468eed-52a8-434b-bc6f-0d60c323f07f (docs/DATA_MODEL.md), read+write:
 * write requires bonding (Phase 5, BLE_GATT_CHR_F_WRITE_ENC below). */
static const ble_uuid128_t s_config_chr_uuid =
    BLE_UUID128_INIT(0x7f, 0xf0, 0x23, 0xc3, 0x60, 0x0d, 0x6f, 0xbc,
                      0x4b, 0x43, 0xa8, 0x52, 0xed, 0x8e, 0x46, 0xc5);

/* 5ebb01c3-8110-4ace-b139-436c1fa0b81f (docs/DATA_MODEL.md), write-only,
 * bonded: the phone writes the current unix time here on every
 * connection (docs/DECISIONS.md D6). Raw 4-byte little-endian uint32,
 * not JSON - a single scalar, matching DATA_MODEL.md's "Little-endian
 * everywhere" convention rather than adding JSON overhead for one number. */
static const ble_uuid128_t s_time_sync_chr_uuid =
    BLE_UUID128_INIT(0x1f, 0xb8, 0xa0, 0x1f, 0x6c, 0x43, 0x39, 0xb1,
                      0xce, 0x4a, 0x10, 0x81, 0xc3, 0x01, 0xbb, 0x5e);

/* 8f2c1e40-7bb5-4b9f-9e11-3c6b9d5a2f77 (docs/DATA_MODEL.md), write-only,
 * bonded: the phone requests a backlog replay of finalized daily
 * aggregates it doesn't have yet (docs/DECISIONS.md D10). Raw 4-byte
 * little-endian uint32 `since_unix_day` - 0 means "everything". Every
 * matching record from stats/daily.bin gets sent as a normal STATS
 * notification (reuses ble_gatt_notify_stats(), same JSON, no new wire
 * format), oldest first. */
static const ble_uuid128_t s_sync_chr_uuid =
    BLE_UUID128_INIT(0x77, 0x2f, 0x5a, 0x9d, 0x6b, 0x3c, 0x11, 0x9e,
                      0x9f, 0x4b, 0xb5, 0x7b, 0x40, 0x1e, 0x2c, 0x8f);

/* Sync backlog replay is paced off a dedicated fast timer, not the
 * write callback itself - draining hundreds of days of history
 * synchronously inside a GATT access callback would stall the NimBLE
 * host task. 100ms x 8 records/tick is 80 records/s, fast enough that
 * even years of daily history replays in well under a minute. */
#define SYNC_BATCH_SIZE 8
#define SYNC_TICK_MS 100

static uint16_t s_stats_val_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint8_t  s_own_addr_type;

/* Phase 5 pairing/bonding state. Physical-access gating (docs/DECISIONS.md
 * D5) is enforced at the link layer, not the SM/encryption layer: Just
 * Works (BLE_SM_IO_CAP_NO_IO, no display on this device) has no app-level
 * hook to refuse an incoming pairing request, so instead the controller's
 * connection whitelist decides who can even connect. Normally only
 * already-bonded peers (BLE_HCI_ADV_FILT_CONN); during the pairing
 * window (button press), anyone (BLE_HCI_ADV_FILT_NONE). */
static bool               s_pairing_mode_active = false;
static esp_timer_handle_t s_pairing_timer;
static ble_addr_t         s_whitelist[MAX_BONDED_PEERS];

/* SYNC backlog replay state (docs/DECISIONS.md D10). s_sync_cursor_unix_day
 * is the next date_unix_day still owed to the phone; sync_tick_cb()
 * advances it as records get sent and stops the timer once it runs off
 * the end of stats/daily.bin. */
static bool               s_sync_pending = false;
static uint32_t           s_sync_cursor_unix_day;
static esp_timer_handle_t s_sync_timer;

/* gatt_advertise() and gatt_gap_event() call each other (advertise passes
 * gatt_gap_event as the connection callback; the event handler re-arms
 * advertising on disconnect/adv-complete/failed-connect), hence the
 * forward declaration. */
static int gatt_gap_event(struct ble_gap_event *event, void *arg);

/* Not exposed by any public header in this ESP-IDF version despite
 * store/config/ble_store_config.h existing - confirmed by grepping the
 * NimBLE tree: even Espressif's own bleprph example forward-declares
 * this exact function itself rather than including something for it. */
extern void ble_store_config_init(void);

/* Builds the docs/DATA_MODEL.md STATS JSON row for one aggregate record,
 * e.g. {"date":"2026-07-02","hour":14,"unique":37,"returning":22,"kanon":false}
 * or, for a whole-day record, "hour":null instead of an integer. Returns
 * the formatted length (as snprintf does), never negative for these
 * fixed-shape inputs. */
static int build_stats_json(const aggregate_record_t *rec, char *out, size_t out_len)
{
    int year; unsigned month, day;
    sd_civil_from_unix_day(rec->date_unix_day, &year, &month, &day);
    const char *kanon = rec->k_anonymity_applied ? "true" : "false";

    if (rec->hour_or_day < 0) {
        return snprintf(out, out_len,
            "{\"date\":\"%04d-%02u-%02u\",\"hour\":null,\"unique\":%u,\"returning\":%u,\"kanon\":%s}",
            year, month, day, rec->unique_count, rec->returning_count, kanon);
    }
    return snprintf(out, out_len,
        "{\"date\":\"%04d-%02u-%02u\",\"hour\":%d,\"unique\":%u,\"returning\":%u,\"kanon\":%s}",
        year, month, day, (int)rec->hour_or_day, rec->unique_count, rec->returning_count, kanon);
}

static int gatt_stats_read(struct ble_gatt_access_ctxt *ctxt)
{
    char json[STATS_JSON_MAX_LEN];
    int len;

    aggregate_record_t rec;
    char path[SD_STATS_PATH_MAX_LEN];
    FILE *f = NULL;
    if (sd_storage_is_ready() && sd_format_stats_today_path(path, sizeof(path)) == 0) {
        f = fopen(path, "rb");
    }

    if (f && fread(&rec, sizeof(rec), 1, f) == 1) {
        fclose(f);
        len = build_stats_json(&rec, json, sizeof(json));
    } else {
        if (f) fclose(f);
        len = snprintf(json, sizeof(json), "{\"error\":\"no_data_yet\"}");
    }

    if (len < 0) return BLE_ATT_ERR_UNLIKELY;
    int rc = os_mbuf_append(ctxt->om, json, (uint16_t)len);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int gatt_config_read(struct ble_gatt_access_ctxt *ctxt)
{
    char json[CONFIG_JSON_MAX_LEN];
    int len = snprintf(json, sizeof(json),
        "{\"rssi_floor\":%d,\"returning_window_days\":%d}",
        runtime_config_rssi_floor(), runtime_config_returning_window_days());

    if (len < 0) return BLE_ATT_ERR_UNLIKELY;
    int rc = os_mbuf_append(ctxt->om, json, (uint16_t)len);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

/* CONFIG write requires an encrypted link (BLE_GATT_CHR_F_WRITE_ENC on
 * the characteristic, only reachable at all by a bonded peer thanks to
 * the connection whitelist above) - a phone mid-pairing but not yet
 * bonded can't sneak a write in during the open pairing window either,
 * since encryption isn't up yet at that point. */
static int gatt_config_write(struct ble_gatt_access_ctxt *ctxt)
{
    char buf[CONFIG_JSON_MAX_LEN];
    uint16_t om_len = OS_MBUF_PKTLEN(ctxt->om);
    if (om_len == 0 || om_len >= sizeof(buf)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;

    uint16_t copied;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &copied) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    buf[copied] = '\0';

    if (!runtime_config_apply_json(buf, copied)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    return 0;
}

/* Write-only: the phone sends its current unix time here on every
 * connection (docs/DECISIONS.md D6). No read/response beyond the
 * standard ATT write ack - nothing to report back. */
static int gatt_time_sync_write(struct ble_gatt_access_ctxt *ctxt)
{
    uint32_t unix_s;
    uint16_t copied;
    if (OS_MBUF_PKTLEN(ctxt->om) != sizeof(unix_s)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(ctxt->om, &unix_s, sizeof(unix_s), &copied) != 0 ||
        copied != sizeof(unix_s)) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    sd_storage_set_wallclock_unix_s(unix_s); /* little-endian on the wire matches this RISC-V target's native layout */
    ESP_LOGI(TAG, "time sync: wallclock set to unix_s=%" PRIu32, unix_s);
    return 0;
}

/* Streams the next batch of matching stats/daily.bin records via
 * ble_gatt_notify_stats() - same JSON, same wire format as a live
 * rollover notify, the phone can't tell the difference. Re-scans the
 * file from the start every tick rather than tracking a byte offset:
 * simpler, and daily.bin stays small (12B/record) even after years of
 * history, so the repeated scan is cheap at this scale. */
static void sync_tick_cb(void *arg)
{
    (void)arg;
    if (!s_sync_pending) return;

    char path[SD_STATS_PATH_MAX_LEN];
    FILE *f = NULL;
    if (sd_storage_is_ready() && sd_format_stats_daily_path(path, sizeof(path)) == 0) {
        f = fopen(path, "rb");
    }
    if (!f) {
        s_sync_pending = false;
        esp_timer_stop(s_sync_timer);
        return;
    }

    aggregate_record_t rec;
    int sent = 0;
    bool more = false;
    while (fread(&rec, sizeof(rec), 1, f) == 1) {
        if (rec.date_unix_day < s_sync_cursor_unix_day) continue;
        if (sent >= SYNC_BATCH_SIZE) {
            more = true;
            break;
        }
        ble_gatt_notify_stats(&rec);
        s_sync_cursor_unix_day = rec.date_unix_day + 1;
        sent++;
    }
    fclose(f);

    if (!more) {
        s_sync_pending = false;
        esp_timer_stop(s_sync_timer);
        ESP_LOGI(TAG, "sync: backlog replay complete");
    }
}

/* Write-only: the phone requests a replay of every finalized daily
 * aggregate it doesn't already have (docs/DECISIONS.md D10). The device
 * doesn't track per-bond sync state - the phone already knows what it
 * has locally and just asks "send me everything from this day on",
 * simpler and survives an app reinstall or a phone swap with no
 * orphaned state left behind on the device. */
static int gatt_sync_write(struct ble_gatt_access_ctxt *ctxt)
{
    uint32_t since_unix_day;
    uint16_t copied;
    if (OS_MBUF_PKTLEN(ctxt->om) != sizeof(since_unix_day)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(ctxt->om, &since_unix_day, sizeof(since_unix_day), &copied) != 0 ||
        copied != sizeof(since_unix_day)) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    s_sync_cursor_unix_day = since_unix_day;
    s_sync_pending = true;
    esp_timer_start_periodic(s_sync_timer, (uint64_t)SYNC_TICK_MS * 1000ULL);
    ESP_LOGI(TAG, "sync requested: since_unix_day=%" PRIu32, since_unix_day);
    return 0;
}

/* Dispatches by characteristic UUID. STATS is read+notify only; CONFIG
 * is read+write (write gated behind encryption, see gatt_config_write);
 * TIME_SYNC and SYNC are write-only, also gated behind encryption. */
static int gatt_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    const ble_uuid_t *uuid = ctxt->chr->uuid;
    if (ble_uuid_cmp(uuid, &s_stats_chr_uuid.u) == 0) {
        return gatt_stats_read(ctxt);
    }
    if (ble_uuid_cmp(uuid, &s_config_chr_uuid.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return gatt_config_write(ctxt);
        }
        return gatt_config_read(ctxt);
    }
    if (ble_uuid_cmp(uuid, &s_time_sync_chr_uuid.u) == 0) {
        return gatt_time_sync_write(ctxt);
    }
    if (ble_uuid_cmp(uuid, &s_sync_chr_uuid.u) == 0) {
        return gatt_sync_write(ctxt);
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_stats_chr_uuid.u,
                .access_cb = gatt_access_cb,
                .val_handle = &s_stats_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            }, {
                .uuid = &s_config_chr_uuid.u,
                .access_cb = gatt_access_cb,
                /* _WRITE_ENC is a permission bit layered on top of the base
                 * _WRITE property, not a replacement for it - without
                 * _WRITE too, the characteristic doesn't advertise write
                 * support at all (confirmed on hardware: nRF Connect showed
                 * "Properties: READ" only until this was added). */
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
            }, {
                .uuid = &s_time_sync_chr_uuid.u,
                .access_cb = gatt_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
            }, {
                .uuid = &s_sync_chr_uuid.u,
                .access_cb = gatt_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
            }, {
                0, /* No more characteristics in this service. */
            }
        },
    },
    {
        0, /* No more services. */
    },
};

static void gatt_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    (void)arg;
    char buf[BLE_UUID_STR_LEN];

    switch (ctxt->op) {
    case BLE_GATT_REGISTER_OP_SVC:
        ESP_LOGI(TAG, "registered service %s handle=%d",
                 ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf), ctxt->svc.handle);
        break;
    case BLE_GATT_REGISTER_OP_CHR:
        ESP_LOGI(TAG, "registered characteristic %s def_handle=%d val_handle=%d",
                 ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf),
                 ctxt->chr.def_handle, ctxt->chr.val_handle);
        break;
    default:
        break;
    }
}

/* Undirected connectable advertising, general discoverable mode, forever
 * (no timeout - re-armed on disconnect/adv-complete below).
 *
 * Flags (3B) + our 128-bit service UUID (18B) + the device name (11B)
 * add up to 32 bytes, one over BLE legacy advertising's hard 31-byte
 * limit (confirmed on hardware: ble_gap_adv_set_fields returned rc=4,
 * BLE_HS_EMSGSIZE, see docs/LEARNINGS.md). The UUID stays in the primary
 * advertisement (so a scanner can filter/identify the service without
 * connecting); the name moves to the scan response, a second, separate
 * 31-byte packet virtually every scanner (including nRF Connect) requests
 * automatically. */
static void gatt_advertise(void)
{
    ble_gap_adv_stop(); /* harmless if not currently advertising */

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    fields.uuids128 = (ble_uuid128_t[]) { s_svc_uuid };
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "error setting advertisement data; rc=%d", rc);
        return;
    }

    struct ble_hs_adv_fields rsp_fields;
    memset(&rsp_fields, 0, sizeof(rsp_fields));

    const char *name = ble_svc_gap_device_name();
    rsp_fields.name = (uint8_t *)name;
    rsp_fields.name_len = strlen(name);
    rsp_fields.name_is_complete = 1;

    rc = ble_gap_adv_rsp_set_fields(&rsp_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "error setting scan response data; rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params adv_params;
    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    /* Discoverable (scannable) by anyone always; connectable only by
     * whitelisted (bonded) peers, except during the open pairing window. */
    adv_params.filter_policy = s_pairing_mode_active ? BLE_HCI_ADV_FILT_NONE
                                                      : BLE_HCI_ADV_FILT_CONN;

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv_params,
                            gatt_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "error enabling advertisement; rc=%d", rc);
    }
}

/* Re-reads bonded peer identity addresses from the NVS store and
 * overwrites the controller's connection whitelist. Called at boot (so
 * pre-existing bonds survive a restart, per docs/TASKS.md Phase 5
 * acceptance criteria) and whenever pairing mode ends (fresh bond added,
 * or window timed out with nothing new). */
static void refresh_whitelist(void)
{
    int count = 0;
    ble_store_util_bonded_peers(s_whitelist, &count, MAX_BONDED_PEERS);
    if (count > 0) {
        ble_gap_wl_set(s_whitelist, (uint8_t)count);
    }
    ESP_LOGI(TAG, "whitelist refreshed: %d bonded peer(s)", count);
}

static void exit_pairing_mode(void)
{
    if (!s_pairing_mode_active) return;

    s_pairing_mode_active = false;
    esp_timer_stop(s_pairing_timer); /* no-op if it already fired */
    ble_gap_adv_stop();              /* down before touching the whitelist */
    refresh_whitelist();
    gatt_advertise();                /* back to whitelist-only filtering */
}

static void pairing_timeout_cb(void *arg)
{
    (void)arg;
    ESP_LOGI(TAG, "pairing window expired, no new bond");
    exit_pairing_mode();
}

static int gatt_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_LINK_ESTAB:
        ESP_LOGI(TAG, "connection %s; status=%d",
                 event->connect.status == 0 ? "established" : "failed",
                 event->connect.status);
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            ble_gattc_exchange_mtu(s_conn_handle, NULL, NULL);
            /* Outside the pairing window only whitelisted (already
             * bonded) peers can even reach this point, so there's
             * nothing to initiate. Inside the window, this is either a
             * brand new phone (the point of pairing mode) or a bonded
             * phone reconnecting during an open window (harmless,
             * restores existing encryption). */
            if (s_pairing_mode_active) {
                ble_gap_security_initiate(s_conn_handle);
            }
        } else {
            gatt_advertise(); /* connection attempt failed, keep advertising */
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnect; reason=%d", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        gatt_advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "advertise complete; reason=%d", event->adv_complete.reason);
        gatt_advertise();
        return 0;

    case BLE_GAP_EVENT_ENC_CHANGE: {
        ESP_LOGI(TAG, "encryption change; conn_handle=%d status=%d",
                 event->enc_change.conn_handle, event->enc_change.status);
        if (event->enc_change.status != 0 || !s_pairing_mode_active) return 0;

        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0 && desc.sec_state.bonded) {
            ESP_LOGI(TAG, "new bond established, closing pairing window early");
            exit_pairing_mode();
        }
        return 0;
    }

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "subscribe event; conn_handle=%d attr_handle=%d cur_notify=%d",
                 event->subscribe.conn_handle, event->subscribe.attr_handle,
                 event->subscribe.cur_notify);
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "mtu update; conn_handle=%d mtu=%d",
                 event->mtu.conn_handle, event->mtu.value);
        return 0;

    default:
        return 0;
    }
}

static void gatt_on_reset(int reason)
{
    ESP_LOGW(TAG, "nimble host reset; reason=%d", reason);
}

static void gatt_on_sync(void)
{
    ble_hs_util_ensure_addr(0);

    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "error determining BLE address type; rc=%d", rc);
        return;
    }

    refresh_whitelist(); /* restore bonds from NVS before the first advertise */
    gatt_advertise();
}

static void gatt_host_task(void *param)
{
    (void)param;
    ESP_LOGI(TAG, "nimble host task started");
    nimble_port_run(); /* returns only on nimble_port_stop() */
    nimble_port_freertos_deinit();
}

void ble_gatt_start(void)
{
    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed (%s), BLE disabled", esp_err_to_name(ret));
        return;
    }

    ble_att_set_preferred_mtu(PREFERRED_MTU);

    ble_hs_cfg.reset_cb = gatt_on_reset;
    ble_hs_cfg.sync_cb = gatt_on_sync;
    ble_hs_cfg.gatts_register_cb = gatt_register_cb;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    /* Bonding (Phase 5, docs/DECISIONS.md D5). sm_mitm=0: the security
     * model here is physical access to the button (link-layer whitelist
     * gating, see gatt_advertise()), not cryptographic MITM resistance -
     * this device has no display/keyboard for anything stronger than
     * Just Works anyway. */
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    ble_store_config_init();

    const esp_timer_create_args_t pairing_timer_args = {
        .callback = pairing_timeout_cb,
        .name = "ble_pairing",
    };
    esp_timer_create(&pairing_timer_args, &s_pairing_timer);

    const esp_timer_create_args_t sync_timer_args = {
        .callback = sync_tick_cb,
        .name = "ble_sync",
    };
    esp_timer_create(&sync_timer_args, &s_sync_timer);

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed; rc=%d", rc);
        return;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed; rc=%d", rc);
        return;
    }

    rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_svc_gap_device_name_set failed; rc=%d", rc);
    }

    nimble_port_freertos_init(gatt_host_task);
}

void ble_gatt_notify_stats(const aggregate_record_t *rec)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;

    char json[STATS_JSON_MAX_LEN];
    int len = build_stats_json(rec, json, sizeof(json));
    if (len <= 0) return;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(json, (uint16_t)len);
    if (!om) {
        ESP_LOGW(TAG, "stats notify: mbuf alloc failed");
        return;
    }

    int rc = ble_gatts_notify_custom(s_conn_handle, s_stats_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "stats notify failed; rc=%d", rc);
    }
}

void ble_gatt_enter_pairing_mode(void)
{
    if (s_pairing_mode_active) return; /* already open, ignore a repeat click */

    s_pairing_mode_active = true;
    ESP_LOGI(TAG, "pairing mode entered, window=%ds", CONFIG_PRINTBACK_PAIRING_WINDOW_SECONDS);
    gatt_advertise();
    esp_timer_start_once(s_pairing_timer,
                          (uint64_t)CONFIG_PRINTBACK_PAIRING_WINDOW_SECONDS * 1000000ULL);
}

bool ble_gatt_pairing_mode_active(void)
{
    return s_pairing_mode_active;
}
