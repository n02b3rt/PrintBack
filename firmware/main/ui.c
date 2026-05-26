#include "ui.h"

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "sdkconfig.h"

#define PIN_BTN  CONFIG_PRINTBACK_PIN_BUTTON
#define PIN_R    CONFIG_PRINTBACK_PIN_LED_R
#define PIN_G    CONFIG_PRINTBACK_PIN_LED_G
#define PIN_B    CONFIG_PRINTBACK_PIN_LED_B
#define LONG_MS  CONFIG_PRINTBACK_LONG_PRESS_MS

static const char *TAG = "ui";

static volatile ui_state_t s_state          = UI_STATE_BOOT;
static volatile bool       s_host_connected = false;
static ui_event_cb_t       s_cb;

static void led_write(uint8_t r, uint8_t g, uint8_t b)
{
#if CONFIG_PRINTBACK_LED_COMMON_ANODE
    r = 255 - r; g = 255 - g; b = 255 - b;
#endif
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, r);
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_1, g);
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_2, b);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_1);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_2);
}

static void led_init(void)
{
    ledc_timer_config_t t = {
        .speed_mode      = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .timer_num       = LEDC_TIMER_0,
        .freq_hz         = 5000,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&t);

    const int pins[3]                = {PIN_R, PIN_G, PIN_B};
    const ledc_channel_t channels[3] = {LEDC_CHANNEL_0, LEDC_CHANNEL_1, LEDC_CHANNEL_2};
    for (int i = 0; i < 3; i++) {
        ledc_channel_config_t c = {
            .gpio_num   = pins[i],
            .speed_mode = LEDC_LOW_SPEED_MODE,
            .channel    = channels[i],
            .timer_sel  = LEDC_TIMER_0,
            .duty       = 0,
            .hpoint     = 0,
        };
        ledc_channel_config(&c);
    }
    led_write(0, 0, 0);
}

static void btn_init(void)
{
    gpio_config_t g = {
        .pin_bit_mask = 1ULL << PIN_BTN,
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&g);
}

static void render(ui_state_t st, int64_t in_state_ms)
{
    switch (st) {
        case UI_STATE_BOOT:
            /* Self-test: R → G → B → W. Lets you verify wiring,
             * pin mapping and CC/CA at first power-on. */
            if      (in_state_ms < 500)  led_write(255, 0,   0);
            else if (in_state_ms < 1000) led_write(0,   255, 0);
            else if (in_state_ms < 1500) led_write(0,   0,   255);
            else if (in_state_ms < 2000) led_write(200, 200, 200);
            else                          led_write(0,   0,   0);
            break;

        case UI_STATE_IDLE: {
            if (!s_host_connected) {
                /* Slow blue blink ~0.66 Hz — firmware alive, nobody on host. */
                if ((in_state_ms / 750) % 2) led_write(0, 60, 200);
                else                         led_write(0, 0,  20);
                break;
            }
            /* slow ~0.5 Hz triangular pulse, dim but visible */
            int t  = (int)(in_state_ms % 2000);
            int up = t < 1000 ? t : 2000 - t;
            uint8_t v = (uint8_t)(up * 60 / 1000);
            led_write(v, v, v);
            break;
        }
        case UI_STATE_ARMED:
            /* amber blink ~4 Hz */
            if ((in_state_ms / 125) % 2) led_write(220, 70, 0);
            else                          led_write(0, 0, 0);
            break;

        case UI_STATE_CAPTURED:
            led_write(0, 220, 0);
            break;

        case UI_STATE_ERROR:
            if ((in_state_ms / 200) % 2) led_write(220, 0, 0);
            else                          led_write(0, 0, 0);
            break;
    }
}

static void ui_task(void *arg)
{
    int64_t press_started = 0;
    bool    long_fired    = false;
    ui_state_t last       = (ui_state_t)-1;
    int64_t state_entered = esp_timer_get_time();

    for (;;) {
        int64_t now = esp_timer_get_time();

        /* Button — polling debounce. The 20 ms tick is the debounce. */
        bool pressed = (gpio_get_level(PIN_BTN) == 0);
        if (pressed) {
            if (press_started == 0) press_started = now;
            if (!long_fired && (now - press_started) >= LONG_MS * 1000LL) {
                long_fired = true;
                if (s_cb) s_cb(UI_EVENT_LONG_PRESS);
            }
        } else {
            press_started = 0;
            long_fired    = false;
        }

        /* LED state machine */
        ui_state_t cur = s_state;
        if (cur != last) {
            last          = cur;
            state_entered = now;
        }
        int64_t in_state_ms = (now - state_entered) / 1000;

        if (cur == UI_STATE_BOOT && in_state_ms > 2200)     s_state = UI_STATE_IDLE;
        if (cur == UI_STATE_CAPTURED && in_state_ms > 1200) s_state = UI_STATE_IDLE;
        if (cur == UI_STATE_ERROR && in_state_ms > 1500)    s_state = UI_STATE_IDLE;

        render(cur, in_state_ms);
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

void ui_init(void)
{
    led_init();
    btn_init();
    s_state = UI_STATE_BOOT;
    xTaskCreate(ui_task, "ui", 3072, NULL, 5, NULL);
    ESP_LOGI(TAG, "ui started (btn=%d r=%d g=%d b=%d)", PIN_BTN, PIN_R, PIN_G, PIN_B);
}

void ui_set_state(ui_state_t st)              { s_state = st; }
void ui_set_event_handler(ui_event_cb_t cb)   { s_cb = cb; }
void ui_set_host_connected(bool connected)    { s_host_connected = connected; }
