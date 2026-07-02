# Host-side unit tests

Testuje czystą logikę z `firmware/main/` bez sprzętu i bez ESP-IDF — zwykłym
gcc na tym komputerze.

## Konwencja

Moduł kwalifikuje się do testowania tutaj, jeśli **nie** ma żadnych include'ów
ESP-IDF/hardware (`freertos/*.h`, `esp_*.h`, `nvs*.h`, `driver/*.h`,
`mbedtls/*.h`) — czyli jest zwykłym, przenośnym C.

Dla modułu `firmware/main/X.c` dodaj tu `test_X.c`. `run_tests.sh` sam
znajdzie parę po nazwie i skompiluje ją hostowym gcc — bez CMake.

## Użycie

```sh
./run_tests.sh
```

## Obecne testy

- `test_kanon.c` — próg k-anonymity (godzinowy
  agregat < 5 zdarzeń → nie publikuj, zbij do dziennego)
