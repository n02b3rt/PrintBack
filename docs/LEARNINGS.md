# Learnings & known issues

Append-only log problemów napotkanych podczas pracy nad firmware/mobile i ich
rozwiązań, żeby nie próbować po raz trzeci czegoś, co już nie zadziałało.
Zawsze dopisuj na dole, nigdy nie kasuj starych wpisów, chyba że problem
przestał być aktualny, wtedy oznacz jako RESOLVED z datą.

Format wpisu:

```
## [FIRMWARE|MOBILE] Krótki tytuł problemu
Data: RRRR-MM-DD
Problem: co się dzieje / jaki błąd
Root cause: (wypełnij po diagnozie)
Fix: (wypełnij po naprawie)
Status: OPEN / RESOLVED (data)
```

Brak wpisów jeszcze, pierwszy pojawi się przy realnej pracy nad refaktorem
(Faza 2, SD card logging).

## Rzeczy które NIE działają: nie próbuj ponownie

- WiFi monitor mode + Thread (802.15.4) na jednym radiu ESP32-C6: potwierdzone
  kolizje radiowe w innym projekcie, nie testować od nowa. Patrz docs/DECISIONS.md D4.
