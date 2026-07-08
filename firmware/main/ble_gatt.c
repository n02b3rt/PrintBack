#include "ble_gatt.h"

#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"

#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "aggregate.h"
#include "sd_storage.h"

static const char *TAG = "ble_gatt";

#define DEVICE_NAME "PrintBack"

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

/* c5468eed-52a8-434b-bc6f-0d60c323f07f (docs/DATA_MODEL.md), read-only in
 * Phase 4 - write needs Phase 5 bonding to authorize it first. */
static const ble_uuid128_t s_config_chr_uuid =
    BLE_UUID128_INIT(0x7f, 0xf0, 0x23, 0xc3, 0x60, 0x0d, 0x6f, 0xbc,
                      0x4b, 0x43, 0xa8, 0x52, 0xed, 0x8e, 0x46, 0xc5);

static uint16_t s_stats_val_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint8_t  s_own_addr_type;

/* gatt_advertise() and gatt_gap_event() call each other (advertise passes
 * gatt_gap_event as the connection callback; the event handler re-arms
 * advertising on disconnect/adv-complete/failed-connect), hence the
 * forward declaration. */
static int gatt_gap_event(struct ble_gap_event *event, void *arg);

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
        CONFIG_PRINTBACK_RSSI_FLOOR, RETURNING_WINDOW_DAYS);

    if (len < 0) return BLE_ATT_ERR_UNLIKELY;
    int rc = os_mbuf_append(ctxt->om, json, (uint16_t)len);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

/* Dispatches by characteristic UUID. Both characteristics are read-only
 * at the ATT layer (flags below), so ctxt->op is always
 * BLE_GATT_ACCESS_OP_READ_CHR here - NimBLE rejects any write attempt
 * before this callback is ever invoked for CONFIG, no manual write
 * handling needed (docs/DECISIONS.md: CONFIG write is Phase 5 scope,
 * once bonding exists to authorize it). */
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
        return gatt_config_read(ctxt);
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
                .flags = BLE_GATT_CHR_F_READ,
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

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv_params,
                            gatt_gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "error enabling advertisement; rc=%d", rc);
    }
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
