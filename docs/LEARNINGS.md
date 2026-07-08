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

## [FIRMWARE] Zero WiFi packets ever received - hardware/antenna, not
coexistence, not a code bug
Date: 2026-07-08
Problem: Phase 4's acceptance criteria (docs/TASKS.md) call for comparing
WiFi probe capture rate before/after enabling BLE. `housekeeper()`'s log
showed `obs=0` across every attempt: toggling the phone's WiFi off/on,
manually refreshing its WiFi scan list, a 3-minute passive capture, and
holding the phone right next to the board's antenna. Zero probe requests
captured by any method, ever.
Investigation (in order, each step ruling out one layer):
1. A/B test, `ble_gatt_start()` removed entirely: still `obs=0`. Rules out
   BLE/coexistence as the cause.
2. Added a raw counter in `on_packet()` incremented unconditionally,
   before any type/subtype filtering (`wifi_sniffer_debug_counts()`,
   temporary, reverted): result `cb_total=0 cb_mgmt=0`, with BLE both on
   and off. The promiscuous callback never fires for ANY frame type, not
   just probe requests - rules out a subtype-filtering bug in
   `on_packet()`.
2b. Compared against ESP-IDF's own `examples/network/simple_sniffer`
   (confirmed to list esp32c6 as a supported target): tried dropping
   `esp_wifi_start()` to match it exactly (no change), tried
   `WIFI_MODE_STA` instead of `WIFI_MODE_NULL`, a very common pattern in
   other ESP32 sniffer projects (no change). Both are legitimate, correct
   patterns elsewhere; neither helped here, weakening "our WiFi init
   sequence is wrong" as an explanation.
3. Decisive test: a completely different, standard API path - a normal
   active WiFi scan (`esp_wifi_scan_start()`, blocking, then
   `esp_wifi_scan_get_ap_num()`), which bypasses promiscuous mode
   entirely and must receive real beacon frames from nearby access points
   to report anything. Result: **`DIAG: active scan found 0 AP(s)`** in a
   normal residential apartment, where at minimum the user's own router
   should be detected. This is not something a code bug in this project
   could cause - it means the radio is not receiving 2.4GHz signals at
   all, full stop.
Root cause: hardware, not software. Most likely candidate given the
physical setup (photographed: XIAO ESP32-C6 on a breadboard with SD-card
jumper wires routed close to the board edge): the antenna keep-out zone
being obstructed, or an antenna path/selection issue specific to this
board. `wifi_sniffer.c`/`tracker.c` are byte-identical between `main` and
`refactor/ble-sd-flutter` (confirmed via `git diff`), so this predates
the whole refactor and isn't a regression from Phase 2/3/4 - real ambient
WiFi capture was never actually confirmed end-to-end on this specific
physical unit before now (Phase 2/3 hardware verification both used
synthetic injected probes, never real ones).
Fix: none possible from firmware. All temporary diagnostic code (raw
packet counters, active-scan probe) was reverted after use - not
committed, not left in the tree. What Phase 4 *did* confirm, independent
of this: BLE GATT (advertise/connect/read/notify) all work correctly on
this same hardware, and running BLE alongside the (non-functional) WiFi
sniffer caused no crashes across many multi-minute test windows - so
whatever the WiFi antenna problem is, it is unrelated to BLE and to
Phase 4's own scope.
Confirmed: user physically reseated the antenna connection on the XIAO
ESP32-C6. Immediately after, the same firmware (no code changes) started
capturing real ambient probes with BLE fully active: `active=1 obs=12
rssi=[-61,-52]` in one 30s window, `sd_bytes` climbing on the SD card as
expected. This is the first real (non-synthetic) WiFi capture confirmed
end-to-end in this project's history, and it happened with BLE running
the whole time - direct evidence WiFi+BLE coexistence itself was never
the problem.
Fix: physical - reseat/fix the antenna connection on the XIAO ESP32-C6.
No firmware change involved. All temporary diagnostic code (raw packet
counters, active-scan probe) was reverted after use, not committed.
Status: RESOLVED (2026-07-08) - root cause was the antenna connection,
not software. Real WiFi+BLE coexistence testing is now possible on this
unit; a proper packets/min before/after comparison (docs/TASKS.md
acceptance criteria) can be revisited now that ambient traffic is
reachable.

## Things that DON'T work: don't try again

- WiFi monitor mode + Thread (802.15.4) on one ESP32-C6 radio: confirmed
  radio collisions on another project, don't retest from scratch. See docs/DECISIONS.md D4.
