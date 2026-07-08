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

## [FIRMWARE] gmtime_r unavailable on the host test toolchain
Date: 2026-07-08
Problem: `firmware/main/sd_paths.c` used `gmtime_r()` to turn a unix day
into Y/M/D for the raw log file name. `firmware/test_host/run_tests.sh`
failed to link on this machine: `undefined reference to 'gmtime_r'`.
Root cause: the host tests build with the MinGW/TDM-GCC toolchain on
Windows, whose libc doesn't provide `gmtime_r()` (POSIX reentrant
variant). The real ESP32 target (newlib) has it, so this only broke the
host-testable build, not the firmware itself.
Fix: dropped the libc time.h dependency entirely and implemented
`civil_from_days()`/`sd_unix_day_from_ymd()` as pure integer arithmetic
(Howard Hinnant's civil_from_days/days_from_civil algorithm) inside
`sd_paths.c`. No time.h, works identically on host gcc and the ESP32
target. Verified against known reference dates (incl. the 2027/2028
leap-year boundary) in `firmware/test_host/test_sd_paths.c`.
Status: RESOLVED (2026-07-08)

## [FIRMWARE] `sd_card` is not a resolvable ESP-IDF 5.3.2 component
Date: 2026-07-08
Problem: Espressif's own bundled example
(`examples/storage/sd_card/sdspi`) lists `REQUIRES fatfs sd_card` in its
CMakeLists.txt. Copying that into `firmware/main/CMakeLists.txt` failed
`idf.py set-target`: `Failed to resolve component 'sd_card'` /
"component ... has been moved to the IDF component manager". Trying
`idf.py add-dependency espressif/sd_card` also failed:
`Component "espressif/sd_card" not found` in the registry either.
Root cause: unclear exactly why the bundled example references a
component name that doesn't resolve in this installed 5.3.2 tree, but
grepping `components/` directly confirmed the actual code lives in
plain, always-available core components: `fatfs` (esp_vfs_fat.h),
`sdmmc` (sdmmc_cmd.h), `esp_driver_sdspi` (driver/sdspi_host.h).
Fix: `REQUIRES fatfs sdmmc esp_driver_sdspi driver` instead of `sd_card`.
Builds clean (`idf.py build` completed, zero warnings in the new files).
Status: RESOLVED (2026-07-08)

## [FIRMWARE] dev_cycle.py fails with WinError 193 on this machine
Date: 2026-07-08
Problem: `python firmware/scripts/dev_cycle.py` fails at the build step:
`OSError: [WinError 193] %1 is not a valid Win32 application`, from
`subprocess.call(["idf.py", "build"], ...)`.
Root cause: not fully diagnosed. `idf.py` on Windows is a script, not a
directly-executable PE binary; `subprocess.call` without `shell=True` (or
without resolving through `python.exe`) can't launch it that way on this
setup even though the ESP-IDF environment is correctly activated (plain
`idf.py build` typed directly into PowerShell works fine).
Fix: none yet, worked around by calling `idf.py build`/`idf.py -p COMx
flash` directly instead of through dev_cycle.py, and using
`--skip-build --skip-flash` (pure pyserial capture, no subprocess) for
the log-reading half, which works. dev_cycle.py's build/flash path
itself needs a real fix (`shell=True`, or resolve to
`sys.executable, idf.py path` explicitly), didn't do that here since
it's a tooling fix orthogonal to Phase 2, flagging instead of guessing
further per the "2 tries and stop" rule.
Status: OPEN

## [FIRMWARE] FAT short filenames silently broke raw log writes
Date: 2026-07-08
Problem: `sd_storage_write_raw()` never wrote a byte on real hardware.
No error visible from probe traffic alone (write just silently no-ops
when the file didn't open). A manual diagnostic write surfaced it:
`E sd_storage: failed to open /sdcard/logs/raw/2026-07-08.bin for append`.
Root cause: ESP-IDF's FATFS defaults to short (8.3) filenames, Long File
Name support is off by default to save RAM. `YYYY-MM-DD` is a 10-character
base name, too long for an 8.3 short name, so `fopen()` failed every time.
Fix: switched the raw log filename format from `YYYY-MM-DD.bin` to
`YYYYMMDD.bin` (8 characters, fits 8.3 without needing LFN). Updated
`docs/DATA_MODEL.md`/`docs/ARCHITECTURE.md` to match. Confirmed on
hardware afterward: `sd_bytes=16` after one record, and a follow-up test
(clock advanced 2 days, retention set to 1 day) confirmed
`purge: deleted 1 raw log file(s)` too.
Status: RESOLVED (2026-07-08)

## Things that DON'T work: don't try again

- WiFi monitor mode + Thread (802.15.4) on one ESP32-C6 radio: confirmed
  radio collisions on another project, don't retest from scratch. See docs/DECISIONS.md D4.
