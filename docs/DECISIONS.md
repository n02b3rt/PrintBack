# Decyzje architektoniczne (ADR-lite) — refaktor PrintBack (BLE + SD + Flutter)

Krótki log "dlaczego zrobiliśmy tak, a nie inaczej", żeby świeża sesja nie
próbowała "poprawić" architektury na coś co wygląda lepiej, nie wiedząc, że
już to rozważaliśmy i odrzuciliśmy.

## D1: BLE zamiast WiFi AP + PWA do syncu danych

Odrzucone: C6 jako WiFi AP + HTTP server serwujący PWA.

Powód: WiFi monitor mode (sniffing) i AP mode nie mogą działać jednocześnie
na tym samym radiu bez przełączania trybów i utraty pakietów. BLE koegzystuje
z monitor mode dużo lepiej (osobny softowy coex, nie wymaga przełączania trybu
WiFi).

## D2: Flutter zamiast PWA dla apki mobilnej

Odrzucone: PWA z Web Bluetooth.

Powód: Web Bluetooth nie działa w Safari/iOS w ogóle, brak obejścia. Flutter
daje jeden kod na Android+iOS z natywnym BLE.

## D3: Agregaty na telefonie, raw dane tylko na SD w urządzeniu

Powód: RODO — zagregowane liczby (bez identyfikatora per-klient) nie są
danymi osobowymi, więc mogą być trzymane bez limitu retencji. Raw dane (nawet
zahashowany MAC) są nadal danymi osobowymi w rozumieniu RODO — stąd twardy
limit 30 dni i to, że NIGDY nie opuszczają urządzenia.

## D4: C6 (nie H2/C6-Thread) do WiFi+BLE

Powód: jeden radio 2.4GHz dzielony softowo (CONFIG_SW_COEXIST_ENABLE) działa
dobrze dla WiFi+BLE (dojrzały, popularny use case — np. BLE provisioning).
WiFi+Thread na tym samym radiu ma dużo gorszy coexistence, potwierdzone
wcześniejszymi testami w innym projekcie — patrz docs/LEARNINGS.md.

## D5: Parowanie — fizyczny przycisk + BLE bonding

Odrzucone: Just Works bez interakcji fizycznej (podatne na zdalny MITM przy
pierwszym parowaniu).

Wybrane: przycisk na urządzeniu uruchamia tryb parowania na czas X, potem
bonding w NVS — wymaga fizycznego dostępu do urządzenia przy pierwszym razie.

## D6: Telefon jako źródło czasu zegarowego

Odrzucone: sprzętowy RTC (np. DS3231 na I2C) — nowy komponent na BOM, nowe
okablowanie, nigdzie wcześniej w projekcie nie planowane.

Odrzucone: czas wyłącznie względem bootu, bez dat kalendarzowych — odbiega
od nazewnictwa plików w docs/TASKS.md (`YYYY-MM-DD.bin`) i utrudnia
czytanie dat wprost.

Wybrane: telefon wysyła bieżący unix time przy każdym połączeniu BLE.
Powód: urządzenie nie ma RTC ani WiFi-STA/NTP (świadomie, zasada "no
network calls"), a telefon i tak musi być fizycznie obecny przy parowaniu i
każdej synchronizacji (D5) — zero nowego sprzętu. Urządzenie trzyma
`esp_timer_get_time()` jako źródło monotoniczne + offset korygowany przy
każdym sync; drift możliwy tylko gdy telefon długo się nie łączy.

## D7: JSON zamiast CBOR dla BLE STATS

Odrzucone: CBOR.

Powód: payload jest i tak mały (<100B/rekord), więc ~30-50% oszczędności
CBOR jest nieistotne przy tej skali. JSON renderuje się czytelnie w
generycznym BLE scannerze (nRF Connect) używanym do weryfikacji w Fazie 4
(docs/TASKS.md) — CBOR wymagałby osobnego dekodera, co utrudnia
samodzielną weryfikację sprzętu. JSON nie wymaga żadnej nowej zależności
on-device (a coexistence build — NimBLE + WiFi + SD + FAT — jest już
wystarczająco złożony), Flutter ma `dart:convert` wbudowane.
