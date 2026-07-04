# Data model — PrintBack (BLE + SD)

Formaty dla docelowej architektury (`refactor/ble-sd-flutter`), kontekst:
[docs/ARCHITECTURE.md](ARCHITECTURE.md). Little-endian wszędzie (RISC-V HP
core na C6) — ważne dla każdego przyszłego narzędzia (Flutter, desktop) które
kiedyś czytałoby surowe pliki `.bin` bezpośrednio.

## Rekord raw na SD

```c
/* firmware/main/sd_storage.h — Faza 2 */
typedef struct __attribute__((packed)) {
    uint32_t timestamp_unix_s;            /* UTC unix seconds. Urządzenie nie
                                            * ma RTC — patrz ARCHITECTURE.md
                                            * "Wall-clock time" (telefon
                                            * nadaje czas przy connect). */
    uint8_t  fp[FINGERPRINT_HASH_BYTES];  /* 8-bajtowy hash IE. NIGDY raw MAC
                                            * — nawet na SD, nie tylko przez
                                            * BLE. */
    int8_t   rssi;                        /* dBm, jak w probe_observation_t */
    uint8_t  channel;                     /* 1/6/11 dziś */
    uint8_t  flags;                       /* bit0 is_new (świeży w 5-minutowym
                                            * RAM-owym oknie trackera, ta sama
                                            * semantyka co dzisiejsze pole
                                            * "new" w JSON-ie)
                                            * bit1 is_returning (patrz
                                            * "Otwarte pytania" niżej)
                                            * bit2 is_whitelisted
                                            * bit3-7 zarezerwowane, zapisuj 0 */
    uint8_t  _reserved;                   /* padding do 16B, zapisuj 0 */
} sd_raw_record_t;                        /* 16 bajtów, jeden rekord = jeden probe */
```

Plik: `/sdcard/logs/raw/YYYY-MM-DD.bin`, append-only, rekordy stałej
długości — rekord N leży pod offsetem N×16, trywialne seek/truncate przy
30-dniowym purge.

## Rekord agregatu

```c
typedef struct __attribute__((packed)) {
    uint32_t date_unix_day;        /* dni od 1970-01-01 UTC (unix_seconds_
                                     * o_północy / 86400). Liczba całkowita,
                                     * nie osobne pola rok/miesiąc/dzień —
                                     * stały rozmiar struktury, zero
                                     * kalendarzowej matematyki on-device;
                                     * konwersja na string daty po stronie
                                     * apki albo przy serializacji do JSON. */
    int8_t   hour_or_day;          /* 0-23 = kubełek godzinowy; -1 = cały
                                     * dzień */
    uint16_t unique_count;         /* unikalne, niewhitelistowane fp w oknie */
    uint16_t returning_count;      /* podzbiór unique_count widziany
                                     * wcześniejszego dnia w oknie returning
                                     * — to samo otwarte pytanie co niżej */
    uint8_t  k_anonymity_applied;  /* bool. Rekordy godzinowe: zawsze 0 —
                                     * rekord istnieje tylko jeśli
                                     * kanon_hourly_publishable() (firmware/
                                     * main/kanon.c) już zwróciło true.
                                     * Rekordy dzienne: 1 jeśli >=1 godzina
                                     * tego dnia została zwinięta do
                                     * dziennego bo sama nie przeszła progu. */
    uint8_t  _reserved[2];         /* padding do 12B, zapisuj 0 */
} aggregate_record_t;              /* 12 bajtów */
```

Pliki: `/sdcard/logs/stats/hourly/YYYY-MM-DD.bin` (append-only, niezmienne po
zamknięciu godziny), `/sdcard/logs/stats/today.bin` (jeden rekord,
nadpisywany w miejscu — pozwala serwować "dziś do tej pory" przez BLE bez
czekania do północy), `/sdcard/logs/stats/daily.bin` (append-only,
sfinalizowane dni, bez limitu retencji — zgodnie z D3, agregaty to nie dane
osobowe).

## BLE STATS payload — JSON (nie CBOR)

Decyzja i uzasadnienie: docs/DECISIONS.md D7. Jeden wiersz agregatu na
notification, nigdy batch:

```json
{"date":"2026-07-02","hour":14,"unique":37,"returning":22,"kanon":false}
```

Rekord dzienny — JSON `null` dla `hour` (nie sentinel `-1` ze struktury C;
to celowa różnica między formatami, nie błąd do "naprawienia"):

```json
{"date":"2026-07-02","hour":null,"unique":142,"returning":88,"kanon":true}
```

**Chunking:** każdy wiersz mieści się z zapasem w realistycznym MTU (BLE
4.2+ negocjuje zwykle 185-247B). Dla bardzo niskiego MTU: 2-bajtowa koperta
fragmentu `[uint8 seq_index][uint8 seq_total]` przed surowymi bajtami UTF-8
JSON, telefon składa fragmenty w kolejności. Urządzenie powinno proaktywnie
poprosić o MTU exchange przy connect, żeby fragmentacja była rzadkim
przypadkiem.

**Backfill po dłuższej przerwie:** urządzenie odtwarza każdy niezsynchronizo
wany wiersz jako kolejne pojedyncze notifications STATS (bez nowego formatu
batch) — nawet po pełnych 30 dniach przerwy to ~750 wierszy, trywialne dla
przepustowości BLE notification. Śledzenie "co już zsynchronizowane z tym
bondem" (np. per-bond ostatni-zsynchronizowany timestamp w NVS) to
implementacja Fazy 4/5.

**Nagłówek formatu pliku (rekomendacja, poza literą TASKS.md):** żaden z
powyższych structów nie ma bajtu wersji/magic. Jeśli layout kiedyś się
zmieni po tym jak Faza 2/3 wyląduje, stare pliki `.bin` staną się
niejednoznaczne. Rekomendacja: 5-bajtowy nagłówek na plik (4B magic + 1B
wersja formatu) — tanie teraz, bolesne do dorobienia później.

## Otwarte pytania — świadomie nierozwiązane w tej fazie

**Algorytm `is_returning`/`returning_count`.** Wymaga trwałego indeksu
"widziany-którego-dnia", którego dziś nigdzie nie ma —`tracker.c` to
wyłącznie RAM, 5-minutowe okno aktywności. Bit/pole rezerwujemy w formacie
już teraz (żeby nie zmieniać layoutu na SD później), ale sam algorytm
(np. skan ostatnich N dni plików raw podczas przebiegu agregacji godzinowej,
albo kompaktowy per-dniowy indeks on-device) to decyzja Fazy 3 — zgodnie z
docs/TASKS.md ("potwierdź dokładną definicję z userem").

**Format cache'u agregatów po stronie Fluttera** — Faza 6 TODO, nie
projektujemy teraz.
