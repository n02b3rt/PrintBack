# Architecture — PrintBack (BLE + SD + Flutter) [SZKIELET — do wypełnienia w Fazie 1]

Ten plik opisuje **docelową** architekturę po refaktorze. Obecny działający
kod (USB-CDC → Python desktop) jest opisany w [README.md](../README.md) i
[docs/compliance/README.md](compliance/README.md) — nie nadpisujemy tamtego
opisu, dopóki refaktor nie jest gotowy (patrz docs/PROGRESS.md Faza 7).

## TODO (wypełnić realną treścią przy projektowaniu, nie zmyślać teraz)

- [ ] Diagram: ESP32-C6 (WiFi monitor + BLE GATT coex) ↔ SD ↔ telefon (Flutter)
- [ ] Podział odpowiedzialności: co liczy firmware on-device vs co robi apka
- [ ] BLE GATT: serwisy/charakterystyki, format agregatów wysyłanych przez BLE
- [ ] SD: struktura plików/rotacji, format raw rekordów (patrz DATA_MODEL.md)
- [ ] Pairing/bonding flow (patrz docs/DECISIONS.md D5)
- [ ] Coexistence config (CONFIG_SW_COEXIST_ENABLE) i ograniczenia (patrz
      docs/DECISIONS.md D4, docs/LEARNINGS.md — WiFi+Thread nie działa)
