# docs/TASKS.md — szczegółowy plan zadań (przebudowa PrintBack: USB/desktop → BLE + SD + Flutter)

Kontekst i twarde zasady: @docs/DECISIONS.md, @docs/compliance/README.md
Zanim zaczniesz KAŻDĄ fazę: przeczytaj @docs/LEARNINGS.md.
Po zakończeniu KAŻDEJ fazy: zaktualizuj @docs/PROGRESS.md, zrób commit,
zapytaj usera zanim przejdziesz dalej — nie łącz faz automatycznie.

Nazwa projektu zostaje **PrintBack** — bez rebrandingu.

---

## FAZA 1 — Dokumentacja bazowa (bez zmian w kodzie)

Cel: mieć spisany kontrakt, zanim cokolwiek się ruszy w firmware.

Zadania:
1. Stwórz `docs/ARCHITECTURE.md` — opis całego systemu: C6 (sniff+SD+BLE),
   telefon (Flutter, cache agregatów), diagram przepływu danych
   (probe request → hash → SD raw → agregacja godzinowa → BLE → telefon).
2. Stwórz `docs/DATA_MODEL.md` — dokładne formaty:
   - rekord raw na SD (pola: timestamp, fp/hash IE, rssi, channel,
     is_new/is_returning, is_whitelisted)
   - rekord agregatu (date, hour_or_day, unique_count, returning_count,
     k_anonymity_applied: bool)
   - payload BLE characteristic STATS (JSON/CBOR schema)
3. Zaktualizuj `README.md` — nowa architektura zamiast USB+desktop,
   nowy przykładowy payload (BEZ pola "mac").
4. Nie ruszaj kodu w tej fazie.

Acceptance criteria: pliki istnieją, są spójne z @docs/DECISIONS.md,
user je przejrzał i zaakceptował.

---

## FAZA 2 — Firmware: SD card logging

Cel: dane trafiają na SD zamiast (albo obok, tymczasowo) na USB.

Zadania:
1. Dodaj moduł `firmware/components/sd_storage/` — driver SPI (sdspi),
   inicjalizacja karty, montowanie FAT.
2. Zdefiniuj strukturę katalogów: `/sdcard/logs/raw/YYYY-MM-DD.bin` (albo
   .csv — zdecyduj i zapisz wybór + uzasadnienie w docs/DECISIONS.md).
3. Zapis rekordu raw przy każdym przechwyconym probe request (format wg
   docs/DATA_MODEL.md) — NIE zapisuj jeszcze surowego MAC-a nigdzie,
   tylko fp (hash IE), zgodnie z istniejącym mechanizmem hashowania.
4. Rolling purge: przy starcie dnia (albo przy boot + raz dziennie timer)
   usuń pliki raw starsze niż 30 dni.
5. Test: podłącz kartę, sprawdź że pliki się tworzą, rotują dziennie,
   i że stare są kasowane (możesz przetestować z krótszym oknem np. 2 min
   zamiast 30 dni, żeby nie czekać miesiąc — potem przywróć 30 dni).

Uwaga: jeśli natrafisz na konflikt pinów SPI z istniejącym LED/przyciskiem
whitelist — nie zgaduj, zapisz w LEARNINGS.md i zapytaj usera o mapowanie
GPIO na płytce, którą realnie posiada.

Acceptance criteria: logi raw lądują na SD w prawidłowym formacie,
rotacja i purge działają, żaden istniejący mechanizm (WiFi sniff,
whitelist heurystyka, watchdogi) nie został zepsuty.

---

## FAZA 3 — Firmware: agregacja on-device + usunięcie raw MAC z payloadu

Cel: urządzenie samo liczy statystyki, surowe dane nigdy nie opuszczają SD.

Zadania:
1. Usuń pole "mac" z jakiegokolwiek istniejącego JSON-a wysyłanego przez
   USB/serial (istniejący kod je zawiera — to ma zniknąć całkowicie).
2. Napisz moduł agregacji: co godzinę licz unique_count i returning_count
   na podstawie logów z bieżącego dnia (returning = fp widziany wcześniej
   w oknie ustalonym w docs/compliance/README.md, np. 24h/7 dni — potwierdź
   dokładną definicję z userem jeśli nie jest jeszcze zapisana).
3. Zaimplementuj próg k-anonymity: jeśli unique_count w danej godzinie < 5,
   NIE publikuj rekordu godzinowego — zamiast tego dolicz do agregatu
   dziennego (rozdzielczość dzienna zawsze ma się publikować, niezależnie
   od progu).
4. Zapisuj agregaty jako osobne, mniejsze rekordy (SD, osobny plik/katalog
   od raw, np. `/sdcard/logs/stats/`) — to jedyne dane, które trafią do BLE.
5. Uwzględnij auto-whitelist heurystykę z istniejącego kodu — urządzenia
   z whitelisty NIE wliczają się do unique/returning count.

Acceptance criteria: żaden raw MAC/hash per-klient nie opuszcza modułu
agregacji, agregaty godzinowe respektują próg k-anonymity, whitelist
działa jak wcześniej.

---

## FAZA 4 — Firmware: BLE GATT server

Cel: urządzenie serwuje agregaty przez BLE, koegzystując z WiFi monitor mode.

Zadania:
1. Włącz `CONFIG_SW_COEXIST_ENABLE`, skonfiguruj BLE stack obok
   istniejącego WiFi monitor mode + channel hopping.
2. Zdefiniuj GATT service z trzema characteristics (UUID-y do ustalenia):
   - STATS (read + notify) — serwuje agregaty wg schematu z DATA_MODEL.md,
     chunkowane pod aktualny MTU
   - CONFIG (read/write) — próg RSSI, okno "returning", trigger resetu
   - PAIRING_STATUS (read/notify) — stan trybu parowania
3. Rozdziel pracę między rdzenie: WiFi sniff+hop na jednym core, BLE stack
   + agregacja + SD writes na drugim (sprawdź obecny podział w istniejącym
   kodzie i dostosuj, nie zgaduj od zera).
4. Test: podłącz się dowolnym generic BLE scannerem (np. nRF Connect) i
   zweryfikuj że characteristic STATS zwraca poprawny JSON/CBOR, a WiFi
   sniffing dalej łapie probe requesty bez zauważalnej degradacji (policz
   pakiety/min przed i po włączeniu BLE — zapisz wynik w LEARNINGS.md).

Acceptance criteria: BLE i WiFi monitor mode działają jednocześnie bez
znaczącej utraty pakietów, characteristics zwracają poprawne dane.

---

## FAZA 5 — Firmware: parowanie (przycisk + bonding)

Cel: bezpieczne, ale wygodne parowanie z telefonem.

Zadania:
1. Wykorzystaj istniejący tact-switch (obecnie używany do whitelist
   capture) — rozszerz jego funkcję o wejście w tryb parowania (np.
   długie przytrzymanie vs krótkie kliknięcie, rozróżnij przez czas).
2. Tryb parowania aktywny przez ograniczony czas (np. 60s), sygnalizowany
   przez istniejący RGB LED (inny kolor/pulsowanie niż stan whitelist).
3. Zaimplementuj BLE bonding — klucze parowania w NVS, kolejne połączenia
   od już sparowanego telefonu automatyczne, bez ponownego wciskania
   przycisku.
4. Test: sparuj raz, zrestartuj urządzenie, sprawdź że ponowne połączenie
   z tym samym telefonem nie wymaga przycisku.

Acceptance criteria: parowanie wymaga fizycznego dostępu do urządzenia,
bonding przeżywa restart, niesparowany telefon nie ma dostępu do
characteristics.

---

## FAZA 6 — Mobile app: szkielet Flutter

Cel: apka łączy się, syncuje agregaty, pokazuje podstawowy dashboard.

Zadania:
1. Nowy katalog `mobile/` — projekt Flutter, dodaj `flutter_blue_plus`
   (albo `flutter_reactive_ble` — zdecyduj i zapisz wybór w DECISIONS.md).
2. Ekran parowania: skan BLE, instrukcja "wciśnij przycisk na urządzeniu",
   obsługa bondingu.
3. Po sparowaniu: subskrypcja characteristic STATS, zapis do lokalnej bazy
   (SQLite/Hive) — WYŁĄCZNIE pola z agregatu (date, hour/day, unique_count,
   returning_count), zero identyfikatorów per-klient.
4. Podstawowy dashboard: wykres dzienny/godzinowy, prosty widok
   nowy/powracający (nie musi być finalny design, ma być funkcjonalny).
5. Ekran ustawień: zmiana progu RSSI / okna returning przez characteristic
   CONFIG.

Acceptance criteria: apka paruje się, syncuje agregaty, pokazuje dane na
wykresie, żadne surowe/identyfikowalne dane nie trafiają do lokalnej bazy
telefonu.

---

## FAZA 7 — Dokumentacja końcowa

Zadania:
1. Zaktualizuj `docs/compliance/README.md` o pełny opis nowego modelu (co,
   gdzie, jak długo — SD 30 dni raw, telefon agregaty bez limitu,
   k-anonymity).
2. Zaktualizuj `README.md` — finalny opis architektury, quick start dla
   nowej wersji, zaktualizowane zrzuty/przykłady.
3. Zachowaj i zaktualizuj sekcję "Honest limits" — dopisz uwagę o
   ograniczeniach k-anonymity threshold przy bardzo małym ruchu.
4. Przejrzyj `docs/LEARNINGS.md` — jeśli są nieaktualne wpisy (problemy już
   nieaktualne po refaktorze), oznacz jako RESOLVED, nie kasuj.

Acceptance criteria: dokumentacja opisuje stan faktyczny repo po
przebudowie, nowy kontrybutor (albo Ty za pół roku) rozumie całość bez
pytania.
