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
