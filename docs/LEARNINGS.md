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

## [FIRMWARE] aggregate.c read its own SD writes as empty (missing dir, missing fsync)
Date: 2026-07-08
Problem: Phase 3 aggregation always saw `unique=0` for an hour that
definitely had probe data written to it, and separately hit
`failed to open /sdcard/logs/stats/today.bin for write`.
Root cause: two distinct bugs found in the same test pass.
(1) `sd_storage_init()` only created `/sdcard/logs/raw`, never
`/sdcard/logs/stats` or `/sdcard/logs/stats/hourly`, so any fopen() into
those directories failed outright (FAT doesn't create missing parent
directories). (2) Even after fixing that, hourly scans still read 0
records. `sd_storage_write_raw()` keeps one `FILE*` open all day
(append) while `aggregate.c` opens a second, independent `FILE*` on the
same path to read it. A plain `fflush()` on the writer only pushes the C
stdio buffer down to the VFS layer; ESP-IDF's FatFs doesn't update the
directory entry's recorded file size until an explicit sync, so a fresh
`fopen()` elsewhere still saw a 0-byte file even after fflush().
Fix: `ensure_dir()` now also creates `stats/` and `stats/hourly/` at
init. `sd_storage_write_raw()` now calls both `fflush()` and
`fsync(fileno(s_raw_fp))` after every write. Confirmed on hardware:
`hour 10: unique=6 returning=0 published=yes`, then a day-rollover test
confirmed `daily rollover: history set rebuilt, 6 unique fp over last
30 days` too.
Status: RESOLVED (2026-07-08)

## [FIRMWARE] BLE advertisement data exceeded the 31-byte legacy limit
Date: 2026-07-08
Problem: on first Phase 4 hardware boot, GATT services registered fine
(confirmed in the log: our custom service and both STATS/CONFIG
characteristics got real attribute handles), but advertising itself never
started: `E ble_gatt: error setting advertisement data; rc=4`.
Root cause: `gatt_advertise()` packed flags (3B) + the device name
"PrintBack" (11B) + our 128-bit service UUID (18B) into one
`ble_gap_adv_set_fields()` call, 32 bytes total. BLE legacy (non-extended)
advertising has a hard 31-byte limit per packet; rc=4 is `BLE_HS_EMSGSIZE`,
confirmed by checking the installed ESP-IDF's NimBLE header
(`components/bt/host/nimble/nimble/nimble/host/include/host/ble_hs.h`)
directly rather than guessing from the number alone.
Fix: split the data across two packets, both of which NimBLE lets you set
independently: the 128-bit UUID stays in the primary advertisement
(`ble_gap_adv_set_fields`, 21B, fits), the device name moves to the scan
response (`ble_gap_adv_rsp_set_fields`, 11B, its own separate 31-byte
packet). Every practical BLE central (including nRF Connect) requests the
scan response automatically, so this is invisible in practice, not a
scoped-down feature. Confirmed on hardware: log now shows `NimBLE: GAP
procedure initiated: advertise` with no error, device visible over BLE.
Status: RESOLVED (2026-07-08)

## [FIRMWARE] Testing WiFi+BLE packet loss needs traffic, and none is
available in this environment
Date: 2026-07-08
Problem: Phase 4's acceptance criteria (docs/TASKS.md) call for comparing
WiFi probe capture rate before/after enabling BLE. With BLE active and a
phone connected over GATT, `housekeeper()`'s log showed `obs=0` across
every attempt: toggling the phone's WiFi off/on, manually refreshing its
WiFi scan list, and a 3-minute passive capture waiting for ambient
household devices to probe on their own. Zero probe requests were
captured by any method.
Root cause: not a coexistence bug. Confirmed with a controlled A/B test:
temporarily removed the `ble_gatt_start()` call from `app_main()`,
rebuilt, reflashed, and ran the same 3-minute passive capture with BLE
fully disabled. Result: also `obs=0`, identical to the BLE-enabled run.
Since the WiFi-only build shows the exact same zero, the missing traffic
is an environmental/methodology gap (no probe requests reaching the
device in this location right now - modern Android throttles/avoids
probing when near a known AP, matching the same difficulty already noted
during Phase 2/3 testing), not something BLE introduced.
Fix: none needed for coexistence itself - no regression found. What *is*
confirmed on hardware, with BLE active: `wifi_sniffer`'s promiscuous mode
stayed up (`sniffer: promiscuous mode active`), `channel_hopper` kept
running, the device never reset, and BLE GATT reads/notify-subscribe
worked correctly throughout multiple back-to-back multi-minute capture
windows - i.e. both stacks ran simultaneously without crashing or
visibly interfering with each other, just without a clean packets/min
number since there was nothing to count either with or without BLE. A
real packets/min comparison needs a controlled traffic source (e.g. a
second, dedicated test device known to probe reliably); revisit if that
becomes available, otherwise this remains an open gap in what Phase 4
could verify.
Status: OPEN (coexistence itself not shown broken, but packet-loss number
from docs/TASKS.md's acceptance criteria not obtained)

## Things that DON'T work: don't try again

- WiFi monitor mode + Thread (802.15.4) on one ESP32-C6 radio: confirmed
  radio collisions on another project, don't retest from scratch. See docs/DECISIONS.md D4.
