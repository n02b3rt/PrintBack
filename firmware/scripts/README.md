# firmware/scripts

`dev_cycle.py`: build + flash + bounded serial capture in one,
non-interactive command. Requires an active ESP-IDF environment (`idf.py`
in PATH) and `pyserial` (already in the Python environment on this machine).

```sh
python dev_cycle.py                          # build + flash + 10s of log
python dev_cycle.py --port COM5 --seconds 30
python dev_cycle.py --skip-build --skip-flash # just tail the log
```

Deliberately doesn't use `idf.py monitor`, that's an interactive terminal
(needs Ctrl+] to exit), so it can't be safely launched from a script. The
capture stops on its own after the given time.
