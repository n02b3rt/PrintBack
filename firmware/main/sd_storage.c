#include "sd_storage.h"

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "sdkconfig.h"

#include "sd_paths.h"

static const char *TAG = "sd_storage";

#define MOUNT_POINT "/sdcard"
#define RAW_DIR     MOUNT_POINT "/logs/raw"

static sdmmc_card_t *s_card = NULL;
static bool s_ready = false;

/* Wall clock: unix_s == s_wallclock_ref_unix_s + (esp_timer_get_time() -
 * s_wallclock_ref_boot_us) / 1e6. No RTC on this board (see
 * docs/ARCHITECTURE.md "Wall-clock time"); the reference point is reset
 * every time sd_storage_set_wallclock_unix_s() is called, whether from
 * the Kconfig fallback at boot or from BLE sync once Phase 4/5 lands. */
static uint32_t s_wallclock_ref_unix_s = 0;
static int64_t  s_wallclock_ref_boot_us = 0;

static FILE     *s_raw_fp = NULL;
static uint32_t  s_raw_fp_day = UINT32_MAX;

static uint32_t current_unix_s(void)
{
    int64_t elapsed_us = esp_timer_get_time() - s_wallclock_ref_boot_us;
    return s_wallclock_ref_unix_s + (uint32_t)(elapsed_us / 1000000);
}

void sd_storage_set_wallclock_unix_s(uint32_t unix_s)
{
    s_wallclock_ref_unix_s = unix_s;
    s_wallclock_ref_boot_us = esp_timer_get_time();
}

bool sd_storage_is_ready(void)
{
    return s_ready;
}

void sd_storage_purge_old(uint32_t retention_days)
{
    if (!s_ready) return;

    DIR *dir = opendir(RAW_DIR);
    if (!dir) {
        ESP_LOGW(TAG, "purge: cannot open %s", RAW_DIR);
        return;
    }

    uint32_t today = sd_unix_day_from_unix_s(current_unix_s());
    uint32_t deleted = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        int y; unsigned m, d;
        if (sscanf(ent->d_name, "%d-%u-%u.bin", &y, &m, &d) != 3) continue;

        uint32_t file_day = sd_unix_day_from_ymd(y, m, d);
        if (!sd_is_purge_candidate(file_day, today, retention_days)) continue;

        char path[SD_RAW_PATH_MAX_LEN];
        if (sd_format_raw_path(file_day, path, sizeof(path)) != 0) continue;
        if (unlink(path) == 0) {
            deleted++;
        } else {
            ESP_LOGW(TAG, "purge: failed to delete %s", path);
        }
    }
    closedir(dir);

    if (deleted) {
        ESP_LOGI(TAG, "purge: deleted %" PRIu32 " raw log file(s) older than %" PRIu32 " days",
                 deleted, retention_days);
    }
}

/* Closes the current raw file (if any) and opens (creating if needed)
 * the raw log file for `today`. No-op if already open for `today` -
 * this makes it cheap enough to call on every single write, so no
 * separate periodic task is needed for day rollover. Also sweeps for
 * old files right after rollover, since that's the natural point a new
 * day's data starts landing anyway. */
static void ensure_raw_file_open(uint32_t today)
{
    if (s_raw_fp && s_raw_fp_day == today) return;

    if (s_raw_fp) {
        fclose(s_raw_fp);
        s_raw_fp = NULL;
    }

    char path[SD_RAW_PATH_MAX_LEN];
    if (sd_format_raw_path(today, path, sizeof(path)) != 0) {
        ESP_LOGE(TAG, "path format failed for unix_day=%" PRIu32, today);
        return;
    }

    s_raw_fp = fopen(path, "ab");
    if (!s_raw_fp) {
        ESP_LOGE(TAG, "failed to open %s for append", path);
        return;
    }
    s_raw_fp_day = today;
    ESP_LOGI(TAG, "raw log: %s", path);

    sd_storage_purge_old(CONFIG_PRINTBACK_SD_RETENTION_DAYS);
}

void sd_storage_write_raw(const probe_observation_t *obs, bool fresh, bool whitelisted)
{
    if (!s_ready) return;

    uint32_t unix_s = current_unix_s();
    ensure_raw_file_open(sd_unix_day_from_unix_s(unix_s));
    if (!s_raw_fp) return;

    sd_raw_record_t rec;
    sd_record_from_observation(obs, unix_s, fresh, whitelisted, &rec);

    if (fwrite(&rec, sizeof(rec), 1, s_raw_fp) != 1) {
        ESP_LOGW(TAG, "raw write failed, dropping record");
    }
}

/* mkdir() that treats "already exists" as success: FAT doesn't create
 * missing parent directories on its own, and we don't want to fail
 * mount on the very common case of a card that's already been used. */
static esp_err_t ensure_dir(const char *path)
{
    if (mkdir(path, 0755) == 0) return ESP_OK;
    return (errno == EEXIST) ? ESP_OK : ESP_FAIL;
}

esp_err_t sd_storage_init(void)
{
    sd_storage_set_wallclock_unix_s(CONFIG_PRINTBACK_FALLBACK_UNIX_EPOCH);

    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 3,
        .allocation_unit_size = 16 * 1024,
    };

    sdmmc_host_t host = SDSPI_HOST_DEFAULT();

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = CONFIG_PRINTBACK_PIN_SD_MOSI,
        .miso_io_num = CONFIG_PRINTBACK_PIN_SD_MISO,
        .sclk_io_num = CONFIG_PRINTBACK_PIN_SD_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4000,
    };

    esp_err_t ret = spi_bus_initialize(host.slot, &bus_cfg, SDSPI_DEFAULT_DMA);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SD: SPI bus init failed (%s), SD logging disabled",
                 esp_err_to_name(ret));
        return ret;
    }

    sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot_config.gpio_cs = CONFIG_PRINTBACK_PIN_SD_CS;
    slot_config.host_id = host.slot;

    ret = esp_vfs_fat_sdspi_mount(MOUNT_POINT, &host, &slot_config, &mount_config, &s_card);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SD: mount failed (%s), SD logging disabled. Check card is "
                 "inserted and wiring (MOSI=%d MISO=%d SCK=%d CS=%d).",
                 esp_err_to_name(ret), CONFIG_PRINTBACK_PIN_SD_MOSI,
                 CONFIG_PRINTBACK_PIN_SD_MISO, CONFIG_PRINTBACK_PIN_SD_SCK,
                 CONFIG_PRINTBACK_PIN_SD_CS);
        spi_bus_free(host.slot);
        return ret;
    }

    if (ensure_dir(MOUNT_POINT "/logs") != ESP_OK || ensure_dir(RAW_DIR) != ESP_OK) {
        ESP_LOGE(TAG, "SD: failed to create %s, SD logging disabled", RAW_DIR);
        esp_vfs_fat_sdcard_unmount(MOUNT_POINT, s_card);
        spi_bus_free(host.slot);
        return ESP_FAIL;
    }

    s_ready = true;
    ESP_LOGI(TAG, "SD ready: %s, %lluMB", s_card->cid.name,
             ((uint64_t)s_card->csd.capacity) * s_card->csd.sector_size / (1024 * 1024));

    sd_storage_purge_old(CONFIG_PRINTBACK_SD_RETENTION_DAYS);
    return ESP_OK;
}
