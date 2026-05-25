idf_component_register(
    SRCS
        "main.c"
        "wifi_sniffer.c"
        "fingerprint.c"
        "tracker.c"
        "output.c"
    INCLUDE_DIRS "."
    REQUIRES
        esp_wifi
        esp_event
        nvs_flash
        mbedtls
        esp_timer
)
