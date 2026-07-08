# Learnings & known issues

Append-only log of problems hit while working on firmware/mobile and
their fixes, so we don't try a third time something that already didn't
work. Always append at the bottom, never delete old entries, unless a
problem stops being relevant, then mark it RESOLVED with a date.

Entry format:

```
## [FIRMWARE|MOBILE] Short problem title
Date: YYYY-MM-DD
Problem: what's happening / what error
Root cause: (fill in after diagnosis)
Fix: (fill in after the fix)
Status: OPEN / RESOLVED (date)
```

No entries yet, the first one will show up during real work on the
refactor (Phase 2, SD card logging).

## Things that DON'T work: don't try again

- WiFi monitor mode + Thread (802.15.4) on one ESP32-C6 radio: confirmed
  radio collisions on another project, don't retest from scratch. See docs/DECISIONS.md D4.
