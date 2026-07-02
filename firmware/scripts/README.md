# firmware/scripts

`dev_cycle.py` — build + flash + bounded serial capture w jednym,
nieinteraktywnym poleceniu. Wymaga aktywnego środowiska ESP-IDF (`idf.py` w
PATH) i `pyserial` (już w środowisku Pythona na tej maszynie).

```sh
python dev_cycle.py                          # build + flash + 10s logu
python dev_cycle.py --port COM5 --seconds 30
python dev_cycle.py --skip-build --skip-flash # tylko podsłuchaj log
```

Celowo nie używa `idf.py monitor` — to interaktywny terminal (wymaga Ctrl+]
do wyjścia), więc nie da się go bezpiecznie odpalić skryptowo. Capture kończy
się sam po zadanym czasie.
