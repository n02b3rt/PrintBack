# Architecture: PrintBack (BLE + SD + Flutter)

Ten plik opisuje **docelową** architekturę na gałęzi `refactor/ble-sd-flutter`.
`main` to dzisiejszy, działający system (USB-CDC → Python/PySide6 desktop +
SQLite), patrz [README.md](../README.md) i
[docs/compliance/README.md](compliance/README.md). Co z tego faktycznie
zbudowane na tej gałęzi: [docs/PROGRESS.md](PROGRESS.md).

## System overview

Dwa węzły, zero trzeciego:

- **ESP32-C6**: sniffuje WiFi probe requesty, hashuje on-chip, zapisuje raw
  dane na SD (30 dni), liczy agregaty godzinowe/dzienne on-device, serwuje
  TYLKO te agregaty przez BLE GATT.
- **Telefon (Flutter)**: BLE central, cache'uje odebrane agregaty lokalnie,
  pokazuje dashboard. Nigdy nie liczy niczego z surowych danych, bo ich
  nigdy nie dostaje.

Żadnej chmury, żadnego serwera, żadnego trzeciego węzła, zgodnie z etosem
całego projektu (docs/compliance/README.md).

## Diagram A: dziś (main branch)

```
[nearby phone]
      │ 802.11 probe request (mgmt frame)
      ▼
┌────────────────────────── ESP32-C6 (firmware/) ──────────────────────────┐
│ wifi_sniffer.c  promiscuous mode, channel-hop {1,6,11} co 400ms           │
│        │ on_packet()                                                     │
│        ▼                                                                 │
│ main.c: on_probe()                                                       │
│    ├─ fingerprint_from_ies()   SHA-256 po stabilnych IE → 8-bajtowy hash │
│    ├─ whitelist_contains(fp)   NVS : RĘCZNY capture przyciskiem, nie ma  │
│    │                           auto-heurystyki mimo że compliance/       │
│    │                           README.md ją opisuje (patrz uwaga niżej) │
│    ├─ tracker_observe(obs)     RAM hash table, 5-minutowe aktywne okno   │
│    └─ output_emit(obs,...)                                               │
│              │                                                           │
│              ▼  jedna linia JSON na probe, USB-CDC 115200 baud           │
│  {"t":..,"fp":..,"mac":..,"rssi":..,"ch":..,"ies":..,"new":..,"wl":..}   │
└──────────────────────────────┬─────────────────────────────────────────┘
                                 │ kabel USB
                                 ▼
                  app/ (Python/PySide6 desktop, komputer operatora)
                  JSON → SQLite (L1 raw 30d / L2 daily-per-fp 365d /
                  L3 daily totals ∞) → dashboard
```

**Uwaga o rozjeździe dokumentacja/kod:** `docs/compliance/README.md` opisuje
auto-whitelist ("6+ godzin w 8h oknie → automatycznie na whitelistę"). Ten
mechanizm **nie istnieje w firmware**: dziś whitelistę buduje się wyłącznie
ręcznym przytrzymaniem przycisku (`ui.c`, `UI_EVENT_LONG_PRESS`, 3000ms).
Nie przenosimy tej nieścisłości do nowej architektury bez świadomej decyzji:
jeśli auto-heurystyka ma powstać, to osobna, nazwana faza, nie coś co się
"już" dzieje.

## Diagram B: docelowo (ta gałąź, po Fazach 2-6)

```
[nearby phone]
      │ 802.11 probe request
      ▼
┌───────────────────────────────── ESP32-C6 ─────────────────────────────────┐
│ wifi_sniffer.c            (bez zmian)                                      │
│ main.c: on_probe() → fingerprint_from_ies() → whitelist_contains()         │
│        ▼                                                                   │
│ tracker.c                 (bez zmian : RAM, 5-min okno, "kto tu jest teraz")│
│        ▼                                                                   │
│ [NOWE] sd_storage: zapis sd_raw_record_t (16B, BEZ MAC)                    │
│        → /sdcard/logs/raw/YYYY-MM-DD.bin      (30-dniowy rolling purge)    │
│        ▼  raz/godzinę + raz/dzień przy rollover                            │
│ [NOWE] agregacja: unique_count / returning_count z dzisiejszych raw        │
│    kanon_hourly_publishable(unique_count)?  (już gotowe: firmware/main/    │
│    kanon.c)                                                                 │
│       tak → dopisz aggregate_record_t godzinowy (k_anonymity_applied=0)    │
│             → /sdcard/logs/stats/hourly/YYYY-MM-DD.bin                     │
│       nie → dolicz do running daily total, k_anonymity_applied=1           │
│             → /sdcard/logs/stats/today.bin (mutowalny) → daily.bin przy    │
│               rollover                                                     │
│        ▼                                                                   │
│ [NOWE] BLE GATT server (CONFIG_SW_COEXIST_ENABLE, jeden rdzeń HP,          │
│        priorytety obok WiFi sniff : patrz "Task scheduling")              │
│    STATS (read+notify) : jeden agregat JSON na notification                │
│    CONFIG (read/write) : progi (RSSI, okno returning)                      │
│    PAIRING_STATUS (read+notify) : stan trybu parowania                     │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                     │ BLE GATT, bonded (D5: przycisk + bonding)
                                     ▼
                       mobile/ (Flutter, flutter_blue_plus)
                       subskrypcja STATS → lokalny cache agregatów → dashboard
                       zero raw danych, zero identyfikatorów per-klient
```

## Podział odpowiedzialności

Urządzenie robi wszystko: sniffing, hashing, dedup, CAŁĄ agregację,
egzekwowanie k-anonymity, retencję/purge. Telefon: BLE central + parowanie/
bonding, cache agregatów lokalnie, render dashboardu, zapis wartości CONFIG.
Telefon **nigdy** nie liczy agregatu z surowych danych, bo surowych danych
nigdy nie dostaje. To twarda, bezwarunkowa zasada (patrz docs/DECISIONS.md D3).

## Task scheduling

ESP32-C6 ma **jeden rdzeń HP (RISC-V, do 160 MHz)** plus osobny co-procesor
LP, który nie odpala ogólnych zadań FreeRTOS (tylko minimalny firmware
wake-source w deep-sleep), nie ma tu podziału na dwa rdzenie do
harmonogramowania. Dziś priorytety FreeRTOS to: `ui_task` (5), `channel_hopper`
(4), `housekeeper` (3), `usb_link_monitor` (2), wszystkie zwykłym
`xTaskCreate` bez pinningu. Docelowo dochodzi BLE stack + zadanie SD/agregacji,
dokładne priorytety to szczegół implementacyjny Fazy 4, nie fiksujemy ich
tutaj.

## Wall-clock time

Urządzenie nie ma zegara czasu rzeczywistego, tylko `esp_timer_get_time()`
(mikrosekundy od bootu, zeruje się przy każdym resecie), zero RTC, zero
WiFi-STA/NTP (świadomie, zgodnie z zasadą "no network calls"). Żeby móc
nazywać pliki na SD po dacie kalendarzowej: **telefon wysyła bieżący unix
time przy każdym połączeniu BLE** (i tak musi być fizycznie obecny do
parowania/synchronizacji, D5). Urządzenie trzyma `esp_timer_get_time()` jako
źródło monotoniczne + offset korygowany przy każdym sync. Przed pierwszym
sparowaniem: brak sensownej daty kalendarzowej, zachowanie na ten wypadek to
implementacja Fazy 2. Decyzja i uzasadnienie: docs/DECISIONS.md D6.

## SD layout

- `/sdcard/logs/raw/YYYY-MM-DD.bin`: raw, 16-bajtowe rekordy stałej
  długości, append-only, 30-dniowy rolling purge (patrz DATA_MODEL.md).
- `/sdcard/logs/stats/hourly/YYYY-MM-DD.bin`: agregaty godzinowe,
  append-only, nie kasowane (agregaty to nie dane osobowe, D3).
- `/sdcard/logs/stats/today.bin`: jeden mutowalny rekord, "dzień w
  trakcie", pozwala serwować "dziś do tej pory" przez BLE bez czekania do
  północy.
- `/sdcard/logs/stats/daily.bin`: sfinalizowane dni, append-only, bez
  limitu retencji.

## BLE GATT (szkic)

Trzy characteristics, dokładne UUID-y i payloady CONFIG/PAIRING_STATUS to
zakres Fazy 4, nie fiksujemy ich tutaj:

- **STATS** (read + notify): jeden wiersz agregatu JSON na notification,
  format: docs/DATA_MODEL.md.
- **CONFIG** (read/write): próg RSSI, okno "returning", trigger resetu.
- **PAIRING_STATUS** (read + notify): stan trybu parowania.

## Coexistence

WiFi monitor mode + BLE: OK, softowy coex (`CONFIG_SW_COEXIST_ENABLE`),
patrz docs/DECISIONS.md D4. WiFi + Thread/802.15.4 na tym samym radiu: NIE,
potwierdzone w innym projekcie, patrz docs/LEARNINGS.md. Nie dotyczy tego
projektu bezpośrednio (nie ma tu Thread), ale zasada obowiązuje na zawsze.

## Pairing/bonding

Fizyczny przycisk + BLE bonding w NVS (docs/DECISIONS.md D5). Dziś przycisk
zna tylko jeden gest (`UI_EVENT_LONG_PRESS`, 3000ms, uzbraja whitelist
capture), dodanie drugiego gestu do wejścia w tryb parowania to szczegół
implementacyjny Fazy 5, nie projektujemy go teraz.
