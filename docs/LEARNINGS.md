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

## [FIRMWARE] Phase 4 packets/min comparison, with real traffic (antenna fixed)
Date: 2026-07-08
With the antenna reseated, ran two clean 5-minute captures back to back,
same location, same ambient conditions: one with `ble_gatt_start()`
active, one with it commented out (temporary, reverted after).
Result: BLE on: 23 observations, 8 unique devices. BLE off: 22
observations, 6 unique devices. Both runs plateaued by ~t=180s then went
quiet (bursty real-world traffic, not a steady rate). The ~4.5%
difference is within the natural variance of ambient traffic between two
separate 5-minute windows (different neighbors' devices happening to
scan at different times), not a measurable WiFi packet loss from
enabling BLE. No crashes, stable heap, in either run.
Status: RESOLVED (2026-07-08) - docs/TASKS.md's Phase 4 acceptance
criterion (WiFi+BLE run simultaneously without significant packet loss)
confirmed with real traffic.

## [FIRMWARE] ble_store_config_init() not exposed by any header
Date: 2026-07-09
Problem: build failed on `ble_store_config_init();` in `ble_gatt.c`:
`implicit declaration of function 'ble_store_config_init'`, even with
`store/config/ble_store_config.h` included.
Root cause: that header only declares the read/write/delete functions;
`ble_store_config_init()` itself isn't exposed by any public header in
this ESP-IDF version. Confirmed by grepping the NimBLE tree: even
Espressif's own `bleprph`/`bleprph_wifi_coex` examples forward-declare
this exact function themselves (`extern void ble_store_config_init(void);`)
rather than including something for it.
Fix: added the same `extern void ble_store_config_init(void);` forward
declaration directly in `ble_gatt.c`, matching the reference examples.
Status: RESOLVED (2026-07-09)

## [FIRMWARE] CONFIG_BT_NIMBLE_NVS_PERSIST didn't take effect from
sdkconfig.defaults alone
Date: 2026-07-09
Problem: bonded, confirmed `whitelist refreshed: 1 bonded peer(s)`, then
restarted the device to test persistence (docs/TASKS.md Phase 5
acceptance criteria) - whitelist came back at 0 bonded peers.
Root cause: same class of issue as Phase 4's BT/coexistence Kconfig
additions (see earlier entry): `firmware/sdkconfig` (the live, gitignored,
generated config) already had `CONFIG_BT_NIMBLE_NVS_PERSIST` recorded as
"not set" from before this option was added to `sdkconfig.defaults`.
Kconfig only applies defaults to options that don't have an existing
recorded value yet, so adding a line to `sdkconfig.defaults` doesn't
retroactively flip an already-decided option in a pre-existing
`sdkconfig`. Third time this exact gotcha has come up (Phase 2, Phase 4,
now Phase 5) - worth remembering as a standing pattern, not a one-off.
Fix: edited the live `firmware/sdkconfig` directly
(`CONFIG_BT_NIMBLE_NVS_PERSIST=y`), rebuilt, reflashed. Re-paired and
confirmed `whitelist refreshed: 1 bonded peer(s)` survives a subsequent
restart.
Status: RESOLVED (2026-07-09)

## [FIRMWARE] CONFIG characteristic showed READ-only despite WRITE_ENC flag
Date: 2026-07-09
Problem: nRF Connect showed `Properties: READ` on the CONFIG
characteristic with no write option available, despite
`.flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE_ENC` in
`ble_gatt.c`.
Root cause: confirmed in `host/ble_gatt.h`: `BLE_GATT_CHR_F_WRITE_ENC`
(0x1000) is a security/permission bit layered on top of the base
`BLE_GATT_CHR_F_WRITE` (0x0008) property flag, not a replacement for it
- same relationship as `_READ_ENC`/`_READ`. Without the base flag, the
characteristic never advertises write support at the ATT layer at all.
Fix: `.flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC`.
Status: RESOLVED (2026-07-09)

## [MOBILE] Flutter wasn't installed, Chocolatey couldn't install it either
Date: 2026-07-09
Problem: `flutter create` failed with "the term 'flutter' is not
recognized" - no Flutter/Dart SDK on this machine at the start of Phase
6. `choco install flutter -y` failed twice: first for lack of an
elevated shell, then (even after answering yes to continue anyway) with
`Chocolatey installed 0/0 packages`, caused by an unrelated corrupted
`C:\ProgramData\chocolatey\lib\python312\python312.nupkg` blocking
Chocolatey's package processing entirely, unrelated to Flutter itself.
Root cause: Chocolatey on this machine is broken independent of
anything Flutter-related; fixing it would mean touching an unrelated
corrupted package outside this project's scope.
Fix: downloaded the official Flutter SDK zip directly from
`https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json`
(current stable at the time: `flutter_windows_3.44.5-stable.zip`),
extracted to `D:\flutter`, added `D:\flutter\bin` to the user's PATH via
`[Environment]::SetEnvironmentVariable(..., "User")`. PATH changes don't
propagate to an already-running shell, so any Flutter invocation in the
same session needs the full path (`D:\flutter\bin\flutter.bat`) until a
fresh shell picks up the new PATH. `flutter --version`/`flutter doctor`/
`flutter create`/`flutter pub get`/`flutter analyze`/`flutter test` all
confirmed working this way - meaning, contrary to the original Phase 6
plan's assumption, these commands (everything except `flutter run`
against a real device/emulator) can in fact be run directly instead of
waiting on the user every time.
Status: RESOLVED (2026-07-09)

## [MOBILE] first real phone run: adb install blocked, then BLE scan permission crash
Date: 2026-07-09
Problem: two separate issues surfaced back to back on the first `flutter
run` against a real Android phone (Xiaomi, MIUI/HyperOS, Android 16).
(1) `adb install` failed every time with `INSTALL_FAILED_USER_RESTRICTED:
Install canceled by user`, even though the APK built fine. (2) After
fixing that, the app launched but tapping "scan for devices" crashed
with `PlatformException(startScan, Permission
android.permission.BLUETOOTH_SCAN required to scan devices, null, null)`.
Root cause: (1) MIUI/HyperOS silently blocks ADB-installed APKs unless
"Install via USB" is explicitly enabled in Developer options, which
itself requires being signed into a Mi Account with network access at
the moment the toggle is flipped - a device/OS setting, not a project
bug. (2) a real code gap: Android 12+ (API 31+) makes
`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` runtime-requestable "dangerous"
permissions. `AndroidManifest.xml` never declared them, and even with
the manifest entries `flutter_blue_plus` does not request the runtime
permission itself before calling native `startScan()` - it just throws.
`ios/Runner/Info.plist` was missing `NSBluetoothAlwaysUsageDescription`
too (iOS prompts automatically off that string but crashes without it).
Fix: (1) user enabled "Install via USB" on the phone, no firmware/app
change needed. (2) added the "no location" manifest block from
flutter_blue_plus's own README (`BLUETOOTH_SCAN` with
`usesPermissionFlags="neverForLocation"`, `BLUETOOTH_CONNECT`, plus
legacy `BLUETOOTH`/`BLUETOOTH_ADMIN`/`ACCESS_FINE_LOCATION` capped at
`maxSdkVersion="30"` for pre-Android-12 devices) to
`android/app/src/main/AndroidManifest.xml`; added
`NSBluetoothAlwaysUsageDescription` to `ios/Runner/Info.plist`; added
`permission_handler` and a `BleService.requestPermissions()` that
requests `Permission.bluetoothScan`/`Permission.bluetoothConnect` before
every `scan()`/`connect()` call on Android (skipped on other platforms -
iOS prompts on its own from the Info.plist string, no explicit request
needed there).
Status: RESOLVED (2026-07-09)

## [MOBILE] TIME_SYNC characteristic invisible to the phone despite existing on the device
Date: 2026-07-09
Problem: after fixing the BLE permission crash above, connect() got much
further (services discovered, STATS/CONFIG matched) but threw `Bad
state: TIME_SYNC characteristic not found`, even though the firmware's
own boot log had already confirmed TIME_SYNC registers correctly
(`registered characteristic 5ebb01c3-... def_handle=20 val_handle=21`).
Root cause: Android caches a peripheral's GATT service/characteristic
table keyed by Bluetooth address, independent of the app and independent
of bonding. This phone had connected to this exact ESP32 (same address)
during earlier Phase 4/5 testing via nRF Connect, back when the firmware
only exposed STATS+CONFIG (TIME_SYNC didn't exist yet). Android kept
serving that stale 2-characteristic table to `discoverServices()`
instead of re-reading the peripheral, since the firmware never sends a
Service Changed indication when its GATT table changes between flashes.
This is expected to recur any time a characteristic is added/changed on
a device Android has seen before, not a one-off - relevant for
PAIRING_STATUS or any future characteristic too.
Fix: `flutter_blue_plus`'s `BluetoothDevice.clearGattCache()` (Android
only, wraps the hidden `BluetoothGatt.refresh()` API) called right after
connecting and before `discoverServices()`, unconditionally on every
connect - cheap, and makes the app resilient to this same class of
problem for the rest of the project instead of a one-time manual phone
fix (forgetting the device in Android Bluetooth settings would have
worked too, but doesn't scale to every tester's phone). Also fixed a
separate own-goal while debugging this: `pairing_screen.dart`'s
`catch (_)` on `ble.connect()` silently swallowed the real exception,
showing only a generic "Connection failed" with no way to see why -
added `debugPrint` of the real error and inlined it into the shown
message, plus descriptive `orElse` on the STATS/CONFIG/TIME_SYNC
`firstWhere` lookups so a real future mismatch says which one failed.
Confirmed on hardware after the fix: `writeCharacteristic` on TIME_SYNC,
`setNotifyValue` on STATS, and `readCharacteristic` on CONFIG all
returned `GATT_SUCCESS` in one connection - the whole Phase 5 bonding +
Phase 6 TIME_SYNC/STATS/CONFIG chain confirmed working end-to-end from
the actual Flutter app for the first time.
Status: RESOLVED (2026-07-09)

## [MOBILE] dashboard showed 0/0 after connecting, no aggregate ever arrived
Date: 2026-07-09
Problem: with the previous two bugs fixed, connect/pair/TIME_SYNC/CONFIG
all worked, but the dashboard's KPI cards stayed at 0/0 and the charts
showed "no data synced yet" right after connecting.
Root cause: not a bug so much as an unfinished piece of scope.
Subscribing to STATS (`setNotifyValue`) only delivers *future*
notifications - the next hourly/daily rollover the device happens to
produce while the phone is connected. docs/DATA_MODEL.md's "Backfill
after a longer gap" section already flagged this as needing a stable
bond identity (Phase 5) to track "what's already synced," but Phase 5's
actual implementation only added bonding/whitelist/CONFIG-write, never
the backfill/replay logic itself - the TODO was never converted into
code.
Fix (partial, deliberately scoped small): STATS also supports a plain
read (`gatt_stats_read()` in firmware, already existed since Phase 4,
returns whatever's in `stats/today.bin` - "today so far"). Added
`BleService.readCurrentStats()` and call it once from
`DashboardScreen.initState()` right after connecting, upserting the
result into the local db like any other row. This is a pull, not a push
through the `statsUpdates` broadcast stream, deliberately: connect()
finishes (and could emit) before the dashboard screen even exists to
subscribe, so anything pushed through the shared stream during connect()
itself would be silently lost to a listener that subscribes too late.
This only gets "today so far" (one record), not a real multi-day
backfill - the full replay-unsynced-history design from
docs/DATA_MODEL.md remains unbuilt, flagging as a real follow-up rather
than improvising a bigger fix mid-session.
Status: RESOLVED (2026-07-09) for the immediate 0/0 symptom. Full
history backfill on (re)connect is still open, not scoped into Phase 6.

## [MOBILE] local_db silently duplicated the daily row on every reconnect
Date: 2026-07-09
Problem: after the STATS-initial-read fix above, the "last days" chart
showed two bars for the exact same date (07-08) instead of one, and the
new/returning KPI cards still read 0/0 despite a daily total clearly
having synced (visible in the duplicated chart bars).
Root cause: two separate bugs. (1) `local_db.dart`'s schema was
`hour INTEGER` (nullable) with `UNIQUE(date, hour)`; daily rows are
stored with `hour = NULL`. SQLite's UNIQUE constraint treats every NULL
as distinct from every other NULL (documented SQLite behavior, not a
bug in SQLite), so the constraint never actually deduplicated repeated
daily-row upserts - every reconnect's `readCurrentStats()` call inserted
a fresh "duplicate" row for the same calendar date instead of replacing
the existing one. (2) `dashboard_screen.dart`'s KPI cards summed
`_hourlyToday` (rows with `hour` 0-23) instead of reading the daily
"today so far" record directly - since the hourly breakdown only fills
in from live hour-boundary notifications (still empty this early), the
KPIs stayed 0/0 even once a real daily total existed in the database.
Fix: (1) switched the `hour` column to `NOT NULL` with `-1` as the
"whole day" sentinel instead of SQL NULL - deliberately matching the
firmware's own on-device convention (`hour_or_day: -1 = whole day`,
firmware/main/sd_paths.h / docs/DATA_MODEL.md), so the UNIQUE index's
normal integer comparison actually catches duplicates. Bumped the
sqflite schema to version 2 with `onUpgrade` dropping and recreating the
table (acceptable for a local dev-stage cache with no real user data to
preserve). (2) KPI cards now prefer `LocalDb.dailyForDate()`'s result,
falling back to the hourly sum only if no daily row exists yet.
Status: RESOLVED (2026-07-09)

## [MOBILE] Kotlin incremental compile crashes after adding shared_preferences (cross-drive pub cache)
Date: 2026-07-10
Problem: `flutter run` (first real build after Phase 8's `pubspec.yaml`
added `shared_preferences`) fails every time at
`:shared_preferences_android:compileDebugKotlin` with
`java.lang.Exception: Could not close incremental caches in
...\shared_preferences_android\kotlin\compileDebugKotlin\...`, root
cause visible a few frames down:
`java.lang.IllegalArgumentException: this and base files have different
roots: C:\Users\norke\AppData\Local\Pub\Cache\hosted\pub.dev\
shared_preferences_android-2.4.26\android\src\main\kotlin\...\Messages.g.kt
and D:\projekty\PrintBack\PrintBack\mobile\android.`
Tried (2 attempts, both reproduced the identical root cause):
1. `flutter clean` + `flutter pub get` + retry - failed with a secondary
   "Storage for [...] is already registered" error, which looked like a
   stale Gradle/Kotlin daemon holding a lock from the first crashed
   attempt.
2. `gradlew --stop` (confirmed it actually had a daemon running: "1
   Daemon stopped") + confirmed no leftover `java.exe` processes + retry
   - failed again with the exact same "different roots" exception as
   attempt 1, ruling out "stale daemon" as the real cause.
Root cause (not yet fixed, diagnosed via the exception text itself, not
guessed): this machine has the Flutter SDK (`D:\flutter`) and this
project (`D:\projekty\PrintBack\PrintBack`) on the `D:` drive, but
`PUB_CACHE` is unset so pub falls back to the default
`C:\Users\norke\AppData\Local\Pub\Cache` - on `C:`. `shared_preferences`
is the first dependency in this project whose Android side is Kotlin
requiring compilation (everything added in Phases 6-7 was Java/pure-Dart
plugins); newer Kotlin Gradle Plugin versions use a "relocatable"
incremental-compilation cache (`RelocatableFileToPathConverter`) that
calls `kotlin.io.File.relativeTo()` between a pub-cache source file and
the project's build directory - `relativeTo()` throws
`IllegalArgumentException` by contract when the two paths don't share a
common root, which two different Windows drive letters never do. This
reproduces deterministically, unrelated to daemon state - explains why
retry #2 hit the identical stack trace instead of a new one.
Next hypothesis (not tried yet, stopping here per the "2 tries" rule to
confirm with the user first): either (a) point `PUB_CACHE` at a `D:`
path (e.g. `D:\pub-cache`) so pub cache and project share a drive root,
requires a fresh `flutter pub get` afterward, or (b) add
`kotlin.incremental=false` to `mobile/android/gradle.properties` to
disable the incremental cache entirely (slower rebuilds, sidesteps the
crash without touching pub cache location). (a) is the more correct fix
since it doesn't just paper over the incremental cache being disabled
project-wide.

Update: user approved (a). Set `PUB_CACHE=D:\pub-cache` (persisted via
`[Environment]::SetEnvironmentVariable(..., "User")`), created the
directory, re-ran `flutter pub get` (confirmed
`shared_preferences_android-2.4.26` etc. actually landed under
`D:\pub-cache\hosted\pub.dev\`, so the env var did take effect for pub).
Retry #1 after this: back to the "already registered" variant, not the
"different roots" one - but `mobile/build/` still had artifacts from the
earlier broken-cache attempts, so ran `flutter clean` + `flutter pub get`
again for a fully fresh state. Retry #2 (clean rebuild, correct
PUB_CACHE, no stale build/ dir): **still fails**, still the "already
registered" storage-conflict variant, zero mention of "different roots"
anywhere in this run's output. This means the cross-drive fix likely did
resolve the original `relativeTo()` crash, but there's a second,
independent problem in the same compile step: something is trying to
register the same incremental-cache storage file
(`...\lookups\id-to-file.tab` etc.) twice within one build, which reads
like a bug in the newer Kotlin "Build Tools API" in-process compiler
daemon itself (a known area of instability in current Kotlin Gradle
Plugin versions), not something fixable by moving files around.
Stopping again rather than guessing further. Candidate next fixes, not
yet tried: `kotlin.incremental=false` in
`mobile/android/gradle.properties` (sidesteps the whole incremental
storage subsystem, not just the drive-letter path through it), or
`org.gradle.parallel=false` (if the double-registration is a
parallel-worker race rather than a pure daemon bug).

Update: user approved trying `kotlin.incremental=false`. Added it to
`mobile/android/gradle.properties`, re-ran `flutter run`. Result: no
crash this time, but the build never finished either - `java`/`dart`
process CPU time stopped climbing (checked twice, ~5 minutes apart,
CPU time moved by under 1 second total both times) while the command
itself produced zero output, not even the normal immediate "Launching
lib\main.dart..." line. Concluded this is a genuine hang, not "just
slower without incremental caching" - killed the background task and
the stuck `java`/`dart` processes manually (`Stop-Process -Force`).
Reverted `kotlin.incremental=false` (made things worse, not better - a
silent hang is harder to diagnose than a crash with a stack trace).
Three real attempts now (cross-drive PUB_CACHE fix, confirmed to fix
its own specific symptom; `kotlin.incremental=false`, causes a hang) -
stopping here per the "2 tries" rule and asking the user directly
rather than guessing a fourth fix, since this is now looking like it
might need something outside what's diagnosable from the Gradle output
alone (a corrupted global `~/.gradle` cache, a JDK/antivirus
interaction, or a genuine upstream Kotlin Gradle Plugin bug needing a
version pin).

Update: user approved clearing the global `~/.gradle/caches` and
`/daemon` (confirmed explicitly, since this affects every Gradle
project on the machine, not just this one). Cleared them, `flutter
clean` + `flutter pub get` in the project, retried. Result: build
succeeded outright - `assembleDebug` in 231s (slow, no incremental
cache to warm-start from, but a normal number for a full rebuild, not a
hang), APK installed, app launched, BLE auto-reconnected without a
manual scan (confirms Phase 8c working too). One genuine corrupted
piece of state was the actual root cause all along: the global Gradle
cache, not (only) the cross-drive pub cache path.
Important correction to the "hang" diagnosis above: re-reading how I
checked it, the "zero output" observation for both the `PUB_CACHE`-only
attempt and the `kotlin.incremental=false` attempt is suspect - both
were run through `... | Select-Object -Last 150` piped into a
backgrounded task. `Select-Object -Last N` buffers its *entire* input
before emitting anything, and `flutter run` never closes its own
stdout (it stays attached for hot reload) - so that pattern will show
literally zero output for the whole lifetime of the process regardless
of whether the build is proceeding normally, slowly, or actually stuck.
The CPU-plateau readings still looked like a real stall in the
`kotlin.incremental=false` case specifically, but given this successful
run also had a multi-minute stretch where CPU barely moved (right after
the heavy compile phase finished, while Gradle was doing lighter
packaging/install work), it's possible that attempt would also have
finished if left running longer, and killing it was premature. Not
re-opening that investigation since the actual fix (global cache clear)
already resolved the real problem either way - but noting this so a
future session doesn't trust a `Select-Object -Last N` pipe as proof of
a hang. For any future long-running `flutter run` via a backgrounded
command, either drop `Select-Object -Last N` entirely or write straight
to a file without a buffering filter in between.
Status: RESOLVED (2026-07-10) - root cause was a corrupted global
`~/.gradle` cache (cleared) compounding a real cross-drive `PUB_CACHE`
issue (also fixed); `kotlin.incremental=false` was an unnecessary
detour, already reverted.

- WiFi monitor mode + Thread (802.15.4) on one ESP32-C6 radio: confirmed
  radio collisions on another project, don't retest from scratch. See docs/DECISIONS.md D4.

## [MOBILE] tryAutoConnect() connected to the wrong bonded BLE device
Date: 2026-07-10
Problem: on two separate fresh app launches, `ConnectingScreen` (Phase 8c
auto-reconnect) connected to an unrelated bonded BLE device on this phone
(address ending `A4:69`, 6 GATT services) instead of the real PrintBack
ESP32 (`...40:9E`, 3 services). `connect()` got far enough to subscribe to
the standard `2a05` Service Changed characteristic (an Android-automatic
step, not app code) before the app was stuck on a device with none of our
characteristics, forcing the user to manually switch devices in Settings
every time.
Root cause: `FlutterBluePlus.systemDevices(withServices: [...])` is
best-effort on Android for a bonded-but-not-currently-connected device -
checking a peripheral's actual GATT services requires a live connection,
which the OS doesn't have yet for a device it just knows is bonded. So
the service-UUID filter can't really filter, and the call can return an
unrelated bonded device, or (confirmed on a later run) return ONLY the
wrong device and never the real one at all.
Fix, two parts: (1) `tryAutoConnect()` now loops through every
`systemDevices()` candidate (preferred/last-used first) and tries
`connect()` on each in turn, relying on `connect()`'s existing
STATS/CONFIG/TIME_SYNC/SYNC lookup (already throws `StateError` if any
are missing) as the "is this actually our device" check - no more giving
up after the first wrong candidate. (2) Since the first run had only one
(wrong) candidate in the list, part 1 alone didn't help on that specific
run - added `_scanAndConnect()` as a further fallback when every
`systemDevices()` candidate fails: a real 5s `startScan(withServices:
[PrintBackUuids.service])`, which filters by the UUID the firmware
actually broadcasts over the air (the same 128-bit UUID from the Phase 4
28-byte-advertisement fix above) rather than the OS's incomplete bonded-
device cache.
Confirmed on hardware: rebuilt and reran twice. First rebuild (loop fix
only, before the scan fallback) reproduced the exact wrong-device-first
symptom with no automatic fallback triggering - `systemDevices()` genuinely
returned only `A4:69` that run, so the loop had nothing else to try;
fell through to the manual pairing screen exactly as designed, user
picked the right device manually, confirming the loop's failure path is
clean at least. Second rebuild (with `_scanAndConnect()` added) connected
straight to `...40:9E` automatically on the very first attempt, no wrong
device, no manual pairing screen - full TIME_SYNC/STATS/CONFIG/SYNC
sequence completed with zero user interaction.
Status: RESOLVED (2026-07-10)

## [FIRMWARE] SYNC never backfilled today's hourly chart, only daily.bin
Date: 2026-07-11
Problem: user feedback after the Phase 8f visual redesign confirmed on
hardware - the dashboard's "Odwiedziny godzinowe (dziś)" (hourly) chart
kept showing "no synced data" on every fresh connect, even once the
daily chart and KPIs were populated correctly from a real SYNC.
Root cause: not a bug, a deliberate earlier scope cut
(docs/DATA_MODEL.md "Backfill after a longer gap" used to say "hourly
historical backfill is out of scope"). `sync_tick_cb()` only ever
replayed `stats/daily.bin`; `aggregate.c`'s `write_stats_hourly()`
already appends every finalized hour to `stats/hourly/<today>.bin` on
the device, that data was just never sent over BLE. Subscribing to STATS
only gets *future* hour-boundary notifications, so on a fresh connect
the hourly chart had nothing until the device happened to cross an hour
boundary while the phone stayed connected.
Fix: user explicitly asked to bring this back in scope. `ble_gatt.c`'s
sync replay is now a two-phase state machine (`sync_phase_t`
SYNC_PHASE_DAILY -> SYNC_PHASE_HOURLY_TODAY): after `stats/daily.bin`
runs out, it starts replaying `stats/hourly/<today>.bin` from hour 0,
same batching/pacing (`SYNC_BATCH_SIZE` per `SYNC_TICK_MS` tick) as the
daily phase, same `ble_gatt_notify_stats()` wire format, so the phone
can't tell an hourly-replay row from a live hour-boundary notification.
Unconditional on every SYNC request (not gated by `since_unix_day`) -
at most 24 small records, and the phone's `local_db` UNIQUE(device_id,
date, hour) already makes a repeat replay a harmless upsert, so there
was no reason to add a second stateful cursor for this on the device
(would contradict docs/DECISIONS.md D10's whole rationale anyway).
Updated docs/DATA_MODEL.md's two SYNC sections to describe the new
second phase instead of the old "out of scope" note.
Status: RESOLVED (2026-07-11) - user flashed the built firmware and
confirmed on their own phone: the dashboard's hourly chart now shows a
real per-hour bar pattern immediately after connecting, no longer
"Brak zsynchronizowanych danych".

## [MOBILE] tapping a chart bar opened two stacked detail sheets
Date: 2026-07-11
Problem: after the Phase 8f tap-to-detail redesign, tapping any bar (
hourly/daily on Dashboard, weekday pattern on Statystyki) opened two
`showModalBottomSheet` instances stacked on top of each other instead
of one, confirmed by the user on real hardware.
Root cause: all three `BarTouchData.touchCallback`s gated on
`event.isInterestedForInteractions`, but that flag is true for more
than one `FlTouchEvent` subtype per physical tap - checked fl_chart
1.2.0's own source (`fl_touch_event.dart`): it's `true` for
`FlTapDownEvent` (among others) and explicitly excludes `FlTapUpEvent`
on mobile. fl_chart's internal gesture handling can fire both a
pan-down and a tap-down callback for the same single tap on Android, so
`isInterestedForInteractions` alone doesn't guarantee "exactly once per
tap" - it's meant for driving hover/highlight visuals across many event
types, not as a single-fire trigger.
Fix: changed all three touchCallbacks to `if (event is! FlTapUpEvent)
return;` instead - `FlTapUpEvent` fires exactly once when the finger
lifts, matching natural tap semantics, and still carries a valid
`localPosition` so the touch response/spot lookup works the same way.
Status: RESOLVED (2026-07-11)

## [MOBILE] weekday pattern chart meaningless for the "Dziś" period
Date: 2026-07-11
Problem: user feedback - selecting "Dziś" (today) in Statystyki still
showed the "Ruch wg dnia tygodnia" (weekday pattern) chart with six
empty bars and one real one, which reads as broken rather than correct.
Root cause: not a bug, a genuine UX gap - `_rangeFor(_Period.today)`
returns a single-day range, so `_daily` can only ever populate one of
the seven weekday buckets. A "pattern across the week" chart is
inherently meaningless with one day of data.
Fix: `statistics_screen.dart` now skips rendering the weekday pattern
section entirely (title + chart) when `_period == _Period.today`,
instead of showing a chart that can't say anything useful for that
selection.
Status: RESOLVED (2026-07-11)

## [MOBILE] Month period folded everything into the 7-bar weekday chart, hourly x-axis unreadable
Date: 2026-07-11
Problem: two related "this chart doesn't work well" reports from the
user. (1) Selecting "Miesiąc" in Statystyki only ever showed the 7-bar
weekday pattern chart (same as week), losing all day-by-day granularity
across up to 30 days of real data. (2) The dashboard's hourly bar chart
showed all 24 hour numbers ("0 1 2 3 4 ... 23") crammed under the bars,
overlapping and unreadable, confirmed on hardware in a screenshot -
`bottomInterval: 4` on `revolutTitles` didn't actually thin the labels
for this bar chart's discrete integer x-axis the way it does for the
daily bar chart's date labels.
Root cause: (1) not a bug, a real UX gap - the weekday chart was the
*only* chart in Statystyki, so "Miesiąc" had nothing better to show than
the same 7 buckets "Tydzień" uses, just averaged over more days. (2) not
fully diagnosed why `interval` doesn't thin a discrete bar axis the way
it thins a line chart's continuous one, not worth chasing further - the
user's own ask ("nie wyświetlajmy godzin") called for removing the
labels entirely anyway, not a better thinning heuristic.
Fix: (1) added `_DailyTrendChart`, a new Revolut-style gradient line
chart (`chart_style.dart`'s new `revolutLine()`) showing daily unique
visits across the selected period, tap-to-detail same as the bar charts
- scales to any number of points (7 for week, 30 for month) without
bar-width cramping, shown above the weekday pattern chart for
week/month (hidden for Today, same reasoning as the weekday chart).
(2) hourly chart now uses a new `revolutTitlesNone` (`FlTitlesData(show:
false)`) instead of numbered labels - exact hour lives in the
tap-to-detail sheet's title, same "no axis clutter" convention the
y-axis already used.
Status: RESOLVED (2026-07-11), not yet re-verified on hardware by the
user for this specific change (previous fixes in this same session
were).

## [MOBILE] Statystyki trend charts extended to two series (Nowi/Powracający)
Date: 2026-07-11
User request: show both "Nowi" (unique) and "Powracający" (returning)
as two lines on the Statystyki trend charts, not just unique - asked
whether this is still RODO-compliant. It is: `unique`/`returning` are
already-aggregated counts (never per-client), already shown side by
side everywhere else in the app (KPI cards, every chart's tap-to-detail
sheet) - this only changes how two already-surfaced numbers are drawn,
adds no new data collection or exposure.
Also folded in a product fix for the "Dziś" period, which previously
had every chart hidden (a single day has no day-over-day trend, and no
weekday pattern): added `_HourlyTrendChart`, the same two-line treatment
but by hour instead of by day, reusing `_hourly` (already loaded for the
peak-hour stat). So every period now has a real trend chart - hourly for
Dziś, daily for Tydzień/Miesiąc - instead of Dziś showing nothing.
`chart_style.dart`'s new `revolutTwoLines()` uses `colorScheme.tertiary`
for the second line, not `secondary`: Material 3's seed algorithm makes
`secondary` a desaturated variant of the *same* hue as `primary` (reads
as "duller teal", easy to confuse at a glance with the primary line),
while `tertiary` is hue-shifted to a genuinely different color - checked
this via the seed algorithm's documented HCT hue-shift behavior, not
verified with a live screenshot (couldn't unlock the user's phone to
check). Added `revolutLegend()` (small "● label" row) since color alone
isn't enough to tell two lines apart reliably.
Status: OPEN - builds/analyzes/tests clean, NOT YET visually verified on
hardware (phone was locked when this landed).

## [MOBILE] hourly labels/peak-hour showed raw UTC hour, not the phone's local wall clock
Date: 2026-07-11
Problem: user noticed the hourly chart's "last reading" was labeled
8:00 despite it being mid-afternoon local time - correctly read as
suspicious, not just quiet traffic. Confirmed via a codebase-wide check
(no `toLocal()`/timezone conversion anywhere in `mobile/lib` except
`ble_service.dart`'s `_writeTimeSync()`, which is for sending the
phone's clock TO the device, unrelated to reading it back): every
hourly label, the "Godzina szczytu" (peak hour) stat, and the hourly
chart's bar/line x-position all used the raw `hour` field straight off
the wire, unconverted.
Root cause: the firmware has no RTC and stores/transmits everything in
UTC (`sd_hour_from_unix_s()`, docs/DATA_MODEL.md) - a deliberate,
correct architectural choice for the device/wire format. But the phone
never converted back to local time before showing it to a human. In
Poland (CEST, UTC+2) a wire `hour: 8` is 10:00 local, not 8:00 - every
hourly label was off by a fixed 2h offset (more in winter CET, UTC+1).
A second, related but narrower bug: `_todayString()`
(`dashboard_screen.dart`) and `_rangeFor()` (`statistics_screen.dart`)
compute "today"/period boundaries from *local* `DateTime.now()`, then
use that string to query rows keyed by *UTC* calendar date - correct
except within about 2h of local midnight, where an hour's true UTC date
differs from its local date.
Fix: added `Aggregate.utcInstant`/`localHour`/`localDate` getters
(`models/aggregate.dart`) - the one conversion point where the phone's
actual timezone enters the picture, computed via `DateTime.utc(...).
toLocal()` rather than a hardcoded offset (correct across DST
transitions automatically). All hour labels, peak-hour bucketing, and
hourly chart grouping (`dashboard_screen.dart`'s `_HourlyBarChart`,
`statistics_screen.dart`'s `_HourlyTrendChart`/peak-hour computation)
now key off `localHour` instead of the raw wire `hour`. To handle the
UTC/local day-boundary edge case correctly rather than just relabeling
around it, both screens now fetch hourly rows with a 1-day UTC pad on
each side of the requested range, then filter to rows whose
`localDate` actually matches the target local day.
Not fixed in this pass (documented, not silently ignored): the
`_todayString()`/`dailyForDate()`/`recentDaily()` *daily* queries and
the weekday-pattern chart's `DateTime.utc(...).weekday` computation
(`statistics_screen.dart`) still use the raw UTC `date` field directly -
correct the overwhelming majority of the day, wrong only for the ~2h
window right after local midnight when the local and UTC calendar dates
briefly disagree. Narrower blast radius than the hourly bug (affects at
most which single day/weekday a record is bucketed under, not a
constant 2h mislabel applied to literally every hourly value), scoped
out of this pass rather than expanding it into a full day-boundary
rework of the daily/weekday query paths too.
Status: RESOLVED (2026-07-11) for hourly labels/peak-hour/hourly chart
grouping - builds/analyzes/tests clean, not yet visually re-verified on
hardware.

## [FIRMWARE] a reflash silently drops the phone's clock correction, new data gets misdated
Date: 2026-07-11
Problem: after reflashing the hourly-backfill/LED changes and confirming
real WiFi capture was working (`active=3 obs=29`, real fingerprints
observed), the live serial log showed `sd_storage: raw log:
/sdcard/logs/raw/20260708.bin` - the device thought it was July 8th,
three days behind the actual date, while it was actively capturing real
traffic. A 90s capture window with no BLE activity at all confirmed the
phone never reconnected during that window.
Root cause: the device has no RTC (docs/ARCHITECTURE.md "Wall-clock
time") - its wall clock is whatever the Kconfig fallback says at boot,
corrected only by a BLE TIME_SYNC write, which the phone sends once per
connection (docs/DECISIONS.md D6). Flashing new firmware hard-resets the
board, which drops any existing BLE connection. `ConnectingScreen`
(`mobile/lib/screens/connecting_screen.dart`) only calls
`tryAutoConnect()` once, at app launch - there's no reconnect-on-drop
logic mid-session. So after any reflash (or brownout, or the phone
walking out of range and back), the device's clock silently reverts to
the stale Kconfig fallback and stays there - misdating every new raw
record and hourly aggregate - until the user manually relaunches the
app or reconnects via Settings. This almost certainly explains the
original "last reading stuck at ~9am" report that started this
investigation: some earlier reflash/reset this morning dropped the
connection, the clock reverted, and nothing corrected it until now.
Fix: none applied yet - this is a real resilience gap, not something
fixed by relaunching once. Candidate fix flagged for a follow-up,
not implemented in this session: have `BleService` listen for an
unexpected disconnect (not a user-initiated one) and automatically
retry `tryAutoConnect()`/`_scanAndConnect()` in the background instead
of leaving the app connectionless until the next full app launch -
mirrors what `ConnectingScreen` already does at startup, just triggered
by a dropped connection instead of only a cold launch.
Fix (user-approved follow-up): `BleService`'s existing `_connSub`
listener already distinguishes a self-initiated disconnect from a real
one for free - `disconnect()` cancels `_connSub` *before* calling
`device.disconnect()`, so a `disconnected` event that actually reaches
the listener can only be an unexpected drop. Added `_scheduleReconnect()`
there: a single retry via `tryAutoConnect()` after a 3s settle delay
(not a backoff loop - if the retry fails the device is genuinely
unreachable, same as any other `tryAutoConnect()` failure, manual
pairing screen is the right fallback). `tryAutoConnect()` already
prefers the last-connected device via the same SharedPreferences key
`connect()` writes on every success, so this naturally retries the
device that just dropped without duplicating that preference logic.
Status: RESOLVED (2026-07-11) for the reconnect-on-drop gap - confirmed
on hardware: reflashed the board while the phone app was already running
(not relaunched), serial log showed `ble_gatt: connection established`
and `time sync: wallclock set` on their own shortly after the reset,
with no manual action on the phone.

## [FIRMWARE] blocking SD/USB I/O inside the WiFi promiscuous callback risked stalling capture over hours
Date: 2026-07-11
User report: separately from the clock/reconnect issue above, WiFi probe
capture has previously stopped entirely after the device ran for a few
hours, recovering only after a power cycle - not something that showed
up in this session's short test windows, reported from the user's prior
experience running the device unattended.
Root cause (code-grounded, not yet confirmed via a multi-hour soak test):
`wifi_sniffer.c`'s `on_packet()` (the `esp_wifi_set_promiscuous_rx_cb()`
callback, which ESP-IDF documents as running in the WiFi driver's own
time-critical context - lengthy work there is a known anti-pattern) was
calling `main.c`'s `on_probe()` synchronously, which does two blocking
I/O operations per matching probe: `sd_storage_write_raw()` (explicit
`fflush()`+`fsync()` per the 2026-07-08 SD fix - not free, and SD
latency isn't constant as a FAT volume fills/fragments over a day) and
`output_emit()`'s `printf()` over USB-CDC (`CONFIG_PRINTBACK_JSON_OUTPUT`
confirmed `y` in the live `sdkconfig` - can back up with nothing draining
it if the device runs standalone/unattended, the real deployment
scenario). Either one growing slower over hours could plausibly stall
the WiFi driver's callback path badly enough that capture appears to
stop, with a power cycle resetting both I/O paths back to a fast state -
matching the reported symptom.
Fix: decoupled capture from processing. `on_packet()` now does only the
fast, CPU-only work (field extraction, IE hashing - unchanged) and pushes
the observation into a new bounded FreeRTOS queue (`xQueueSend`, zero
timeout - drops and counts rather than blocking the driver callback if
the queue is ever full). A new dedicated task (`probe_proc_task`) is the
only thing that calls `cb` (`on_probe()`), entirely off the WiFi driver's
callback path - however slow SD/USB I/O gets, it can now only ever back
up the queue, never stall capture itself. Added
`wifi_sniffer_dropped_count()`, logged in `housekeeper()`'s existing
stats line (`dropped=`) for visibility if the consumer task ever falls
behind for real.
Status: OPEN (mitigated) - builds clean, flashed, confirmed no
regression on a short real-traffic test (`active=1 obs=8 dropped=0`,
real fingerprints captured, SD writes succeeding). The actual multi-hour
degradation this targets can't be reproduced or disproven in one dev
session - needs a real unattended multi-hour run to confirm `dropped`
stays near 0 and capture keeps working past the point where it
previously stopped.

## [MOBILE] connect() had no reentrancy guard, auto-reconnect raced concurrent GATT writes
Date: 2026-07-11
Problem: during the Etap 0 hardware verification session (SYNC hourly
backfill test), the phone's pairing screen showed "Połączenie nieudane"
twice with different underlying causes, both on `writeCharacteristic`:
`PlatformException(writeCharacteristic, gatt.writeCharacteristic()
returned 201 : ERROR_GATT_WRITE_REQUEST_BUSY, null, null)` and
`FlutterBluePlusException | writeCharacteristic | fbp-code: 1 | Timed
out after 15s`. The firmware's serial log showed a repeated
connect/disconnect loop (`ble_gatt: disconnect; reason=531` - HCI 0x13,
remote-terminated - every ~15-40s, each followed by `connection
established` again) for several minutes, even though one connection in
the middle of it completed `time sync` + `sync: backlog replay
complete` cleanly.
Root cause: `BleService.connect()` (`mobile/lib/ble/ble_service.dart`)
had no guard against running twice concurrently. `_scheduleReconnect()`
(added earlier today, auto-reconnect on an unexpected drop) fires
`tryAutoConnect()` -> `connect()` 3s after any disconnect; if that raced
against another in-flight `connect()` (a manual retry from the pairing
screen, or a second reconnect timer firing before the first attempt's
GATT operations had actually finished at the OS level), two
`writeCharacteristic()` calls landed on the same GATT connection at
once - Android's stack answers the second one with
`ERROR_GATT_WRITE_REQUEST_BUSY` or lets the first one time out. Either
way `connect()` throws partway through, `_device`/`_connSub` are left in
a half-set state, and the resulting disconnect/retry repeats the same
race. Checked `HomeShell`'s own `requestSync()` (the only other
`writeCharacteristic` caller) and ruled it out - it only fires once from
`initState()`, before any reconnect could occur, so this isn't a factor.
Fix: added a `bool _connecting` guard around `connect()`'s whole body
(set at entry, cleared in a `finally`); a second concurrent call now
throws `StateError('connect() already in progress')` immediately
instead of racing a live write. Every caller (`tryAutoConnect()`'s loop,
`_scanAndConnect()`, `_scheduleReconnect()`) already treats any
`connect()` failure as "try the next candidate / give up for now", so
failing fast needed no new handling.
Status: OPEN - `flutter analyze`/`flutter test` clean, rebuilt and
reinstalled on the test phone over adb; not yet re-verified on hardware
that the connect/disconnect loop actually stops - that's the immediate
next step of the same Etap 0 hardware session.

Update (same date, continued hardware session): re-verification showed
the connect/disconnect loop recurring even with the `_connecting` guard
in place, so the reentrancy race was real but not the only cause.
Additional findings from a live, unbuffered serial capture across many
repeated cycles:
- The board reset itself at some point mid-session (uptime restarted
  from ~0; the boot banner and real reset reason were lost because the
  serial capture wasn't watching yet - see the separate "capture
  buffering" note below). `sd_storage: raw log:
  /sdcard/logs/raw/20260708.bin` after the reset confirms the wallclock
  reverted to the stale Kconfig fallback date, exactly the class of
  problem 9b (not yet implemented) is meant to fix - expected given the
  reset, not a new bug on its own.
- Every single post-reset connection attempt (many cycles observed)
  shows `connection established` -> `mtu update` -> a `subscribe event;
  attr_handle=8 cur_notify=0` (an OS-automatic CCCD event, not our app
  code - our own STATS subscribe would show `attr_handle=16
  cur_notify=1`, never observed in any of these cycles) -> then either a
  ~15-22s stall ending in `disconnect; reason=531`, or (once) an explicit
  `encryption change; conn_handle=0 status=13` before the disconnect.
  Checked NimBLE's `ble_hs_err.h`: status 13 = `BLE_HS_ETIMEOUT` - the
  encryption/bonding renegotiation with the already-bonded phone timed
  out at the BLE link layer itself, before the app's `connect()` ever
  got a chance to call `discoverServices()`/write TIME_SYNC. `attr_handle
  =16` (our own STATS notify) and `time sync:` never appear again in any
  cycle after the reset, meaning the app-level flow this session's fix
  targeted isn't even being reached - the failure moved earlier, to the
  BLE encryption handshake itself.
- The loop is self-sustaining without any user action: cycle time
  dropped from ~15-40s (before the reentrancy fix) to a fairly steady
  ~7-11s (connect -> disconnect -> `_scheduleReconnect()`'s 3s timer ->
  connect again), consistent with the app's own auto-reconnect hammering
  a link that cannot complete encryption, not a user retrying manually.
- Separately (tooling, not a project bug): the first live-capture attempt
  after the fix produced an empty log file with zero Monitor
  notifications - `dev_cycle.py`'s stdout is fully block-buffered by
  Python when piped (not a TTY), so `print()` output sat in an internal
  buffer and was lost when the process was stopped instead of reaching
  `tee`/`grep` in anything close to real time. Fixed by invoking
  `python -u firmware/scripts/dev_cycle.py ...` (unbuffered stdout) for
  every capture from that point on - worth remembering for any future
  live-log session, this file doesn't otherwise track tooling-only
  findings but this one directly caused a diagnostic dead end mid-session.
Next hypothesis (not tried - stopping here per the "2 tries" rule and
CLAUDE.md's "real BLE pairing: always ask instead of guessing
repeatedly", since `BLE_HS_ETIMEOUT` on encryption is a link-layer/radio
symptom, not something a third blind app-code change is likely to fix):
either genuine RF/interference in this test session (unrelated devices,
antenna position - same general class as the 2026-07-08 WiFi antenna
finding, though that was WiFi not BLE), or the ESP32's bonding/bond-store
state got into a bad spot specifically because of the unexplained reset
mid-session (NVS-persisted bond record vs. some in-RAM SMP state now
disagreeing). A clean test would be: fully forget/unpair the device on
the phone's system Bluetooth settings (not just the app's "aktywne
urządzenie"), power-cycle the ESP32 fresh, and re-bond from scratch
during a fresh pairing window - rules out stale bond state on either
side at once. Not attempted without asking first, since it's a step
outside pure app code and outside Etap 0's actual scope.
Status: OPEN - reentrancy-guard fix (`30f8e56`) is real and stays (it
prevents a genuine, separate race), but does not by itself explain the
symptom the user is seeing. Root cause of the encryption-timeout loop is
unconfirmed; asked the user how to proceed rather than attempting a
third change blind.

Update (same date, root cause found): the user ran `flutter run` directly
against the phone themselves, giving visibility this session never had
before - the full native Android `BluetoothGatt`/`[FBP-Android]` log, not
just the ESP32 serial side. That log settled it:
- `tryAutoConnect()` still tries the wrong bonded device
  (`...A4:69`, 6 services - the same watch/band from the 2026-07-10
  entry) before the real one (`...40:9E`, 3 services) on every attempt -
  that recurrence is real but not the crash cause, just wasted time.
- The connection to the real device (`...40:9E`) reached
  `discoverServices` -> `setNotifyValue` -> `onMethodCall:
  writeCharacteristic` (our own `_writeTimeSync()`) cleanly every time -
  never a radio-level problem. A `BleService.disconnect()` stack-trace
  probe (temporary, added then reverted) proved the mid-write disconnect
  was *not* coming from our own `disconnect()` method at all - the error
  surfaced instead as `FlutterBluePlusException | connect | android-code:
  22 | CONNECTION_TERMINATED_BY_LOCAL_HOST` thrown from a *second*,
  independent `BluetoothDevice.connect()` call (from
  `_PairingScreenState._connect()`, i.e. the user tapping a device tile)
  landing on the *same* device address while the first connection
  attempt's native `BluetoothGatt` client was still open with a pending
  write.
Root cause: `connect()` never cleaned up on failure. If anything inside
it threw (permission denied, a characteristic not found, `_writeTimeSync()`
not resolving in time), the `try`/`finally` only reset the `_connecting`
guard - it never called `disconnect()` or cleared `_device`, so the
native GATT client and the open connection were left dangling. Any later
`connect()` call to the *same* device (a manual retry, a fresh
`tryAutoConnect()` cycle) then raced against that orphaned native
connection instead of starting clean, and Android tore down whichever
one lost with `CONNECTION_TERMINATED_BY_LOCAL_HOST` - explaining every
symptom from this whole investigation (the original `PlatformException
... ERROR_GATT_WRITE_REQUEST_BUSY`, the `Timed out after 15s` errors, and
the `encryption change; status=13` / `BLE_HS_ETIMEOUT` seen from the
ESP32 side, which was a downstream symptom of the phone colliding with
its own zombie connection, not a genuine radio-level pairing failure).
The reentrancy guard from earlier today (`30f8e56`) was necessary but not
sufficient - it stops two *simultaneous* Dart-level calls from racing
live writes, but a connection that already failed and left a dangling
native client isn't "in progress" by that flag, so a *later* call sailed
straight past the guard into the zombie.
Fix: `connect()`'s body is now wrapped in `catch (e) { try { await
disconnect(); } catch (_) {} rethrow; }` before the existing `finally`
that clears `_connecting` - every failure path now leaves the same clean
slate a successful `disconnect()` would, instead of an orphaned native
connection for the next attempt to trip over.
Status: RESOLVED (2026-07-11) - `flutter analyze`/`flutter test` clean.
Not yet re-verified end-to-end on hardware (next step: hot-restart and
retry). The wrong-bonded-device-first recurrence
(`tryAutoConnect()`/`systemDevices()` still returning the watch before
the real device, same underlying cause as the 2026-07-10 entry above)
is real but unrelated to this fix - flagged here, not re-opened as its
own investigation in this session.

Update (same date, hardware re-verification): the fix works as designed
- every attempt against the wrong device (A4:69) and every attempt
against the real device (40:9E) now ends in a clean, deliberate
`disconnect()` (`status: SUCCESS`) instead of colliding with an orphaned
connection. But this exposed the real, still-open problem underneath:
**every single connection attempt to the real device, even a completely
solo one with nothing else racing it, fails at exactly the same step -
right after `onMethodCall: writeCharacteristic` (our `_writeTimeSync()`)
- with `CONNECTION_TERMINATED_BY_LOCAL_HOST` or `fbp-code: 6 | Device is
disconnected`.** MTU negotiates fine (247), `discoverServices` and
`setNotifyValue` (the automatic 0x2a05 Service Changed subscribe) both
succeed every time - only the TIME_SYNC write itself never completes.
Next hypothesis (not attempted - this would be a third code change in
one session, past the "2 tries" line, and edges further into "real BLE
pairing" territory CLAUDE.md says to ask about rather than keep
guessing): TIME_SYNC requires an encrypted link
(`BLE_GATT_CHR_F_WRITE_ENC`, `firmware/main/ble_gatt.c`). Android
reports a bonded device as "connected" as soon as the basic link forms,
but re-establishing *encryption* with an already-bonded peer is a
separate, slightly-later SMP exchange - there's evidence this exact gap
is real: the ESP32 serial log earlier in this same session recorded
`encryption change; conn_handle=0 status=13` (`BLE_HS_ETIMEOUT`) on one
of these attempts. If `_writeTimeSync()` fires immediately after
`discoverServices()`/`setNotifyValue()`, before Android has actually
finished re-encrypting the link, the peripheral would reject the write
(insufficient encryption) and the resulting ATT error could plausibly
surface exactly as an immediate local disconnect rather than a clean
Dart-level error - matching what's observed. A confidence-building next
step that needs no more code: watch the *next* hardware attempt's ESP32
serial log specifically for whether `encryption change; status=0`
(success) appears at all before the write, and if so, how long after
`connection established` it lands relative to when the phone issues the
write.
Status: OPEN - two real, justified fixes landed this session
(reentrancy guard `30f8e56`, cleanup-on-failure `2d2cfea`), but the
user-visible "can't pair" symptom persists. Stopping here per the "2
tries" rule instead of attempting a third blind change; asked the user
how to proceed.

Update (same date, user explicitly said to keep going): tried the
encryption-settle hypothesis as a code change (`8bea399`) - 500ms delay
before the first `_writeTimeSync()` plus one catch-and-retry with
another 500ms, per flutter_blue_plus's own README guidance for this
class of Android flakiness. **Did not fix it** - next attempt failed
with `fbp-code: 6 | Device is disconnected` on writeCharacteristic,
i.e. the link was already gone before even the delayed first write.
That result actually narrows things further: the disconnect is not
racing our write at all - the link is dying on its own between
service discovery and the first ATT operation over an encrypted
characteristic. Combined with the two hardest facts of the session -
(a) this exact phone+device pair completed a full TIME_SYNC + SYNC
replay flawlessly earlier the same evening (22:14, first capture), and
(b) the failures started immediately after the board's unexplained
spontaneous reset - the strongest remaining hypothesis is a **bond key
mismatch**: the phone re-encrypts with its stored LTK, the device no
longer accepts it (bond store state diverged around the reset), the SMP
re-encryption times out (`encryption change; status=13` seen on the
device), and Android tears the link down locally. No app code can fix
mismatched keys; the deterministic test/repair is deleting the bond on
BOTH sides and re-pairing fresh: forget "PrintBack" in the phone's
system Bluetooth settings (app-level "forget" doesn't touch the OS
bond), hard-reset the board (done over serial via esptool), open the
pairing window with the button, connect fresh. NimBLE overwrites the
stale bond for the same peer on re-pair, so the device side doesn't
need an NVS wipe for this test - that's the escalation step only if a
fresh re-pair still fails.
Status: OPEN - fresh re-pair test prepared and running (board reset,
phone's Bluetooth settings opened via adb, serial capture live);
outcome to be recorded here.

Update (same date, RESOLVED): the plain board reset alone did not help
(same stall), and a full phone restart did not help either (connection
passed the whitelist, then ~35s of silence with no SMP at all, then the
phone dropped the link) - which ruled out a wedged phone stack and left
exactly one stale-state holder: the device's own bond store. With the
user's explicit approval, erased the device's NVS partition
(`parttool.py erase_partition --partition-name=nvs` - kills the bond
store and the two runtime-config values, touches nothing on the SD
card), hard-reset, opened a fresh pairing window, and the very next
pairing attempt from the same phone completed the entire chain in
seconds: `encryption change; status=0` -> `new bond established` ->
`time sync: wallclock set` -> `sync: backlog replay complete`, followed
by a live hour-23 finalization and the deferred daily rollover (the
clock jumped 3 days forward from the stale Kconfig fallback, D6's
drift-then-catch-up behaving exactly as designed) streaming to the
phone as STATS notifies. Connection then stayed up with zero drops.
Final picture: the phone had silently lost its bond record (PrintBack
gone from system Bluetooth settings; plausibly during the phone-side
Bluetooth flakiness observed mid-session) while the device still held
its half of the bond - an asymmetry neither side could recover from on
its own, and which no app-level code could fix. The three app fixes
landed along the way (`30f8e56` reentrancy guard, `2d2cfea`
cleanup-on-failure, `8bea399` settle-delay+retry on the first encrypted
write) are each independently justified and stay; a fourth speculative
change (explicit createBond()/removeBond() ladder) was written but
reverted uncommitted once the wipe fixed the real problem - per repo
rules, no untested speculative code on top of a working state.
Two follow-ups worth remembering: (1) the device-side bond store can
hold the whole product hostage when the phone loses its bond - a
"factory reset" gesture (long-press variant or similar) that clears
bonds without a PC and esptool is worth considering for a future phase,
a shop owner can't run parttool; (2) the board's original spontaneous
reset that evening remains unexplained - nothing in any capture showed
a panic or brownout marker, watch for recurrence during the 30-day
soak.
Status: RESOLVED (2026-07-11) - root cause: one-sided (device-side)
stale BLE bond after the phone silently lost its own; fix: NVS erase +
fresh pairing. Confirmed on hardware end-to-end, connection stable,
full sync replay verified.

## [FIRMWARE] board went unresponsive after an unclean USB power removal, only a physical replug recovered it
Date: 2026-07-12
Problem: during Phase 10 on-device testing, after the board had been
physically unplugged from USB mid-session (part of an offline-mode test
that called for cutting the device's power), the phone app could no
longer see or pair with it - a general BLE scan returned nothing and the
physical pairing button did nothing. A serial capture on the same COM
port that had been working earlier the same day showed ZERO output over
multiple 35-40s windows (not even the housekeeper's 30s stats line),
ruling out "just quiet traffic".
Investigation (each step ruled out one layer): plain pyserial capture -
silent; capture with DTR/RTS deasserted (to rule out pyserial holding
the ESP32-C6 in reset via the USB-serial-jtag control lines) - still
silent; `esptool ... read_mac`/`chip_id` - succeeded (so the chip is
alive and responds at the ROM level); `idf.py flash` of the same frozen
build - wrote and verified successfully, hard-reset "Done", but the app
STILL produced no serial output afterward. So: chip alive at ROM,
flashing works, but the application firmware would not run/advertise -
which explained both app-side symptoms at once (no BLE advertising, and
a button the non-running app couldn't service).
Root cause: not fully diagnosed at the register level, but empirically
the ESP32-C6's native USB-serial-jtag got into a wedged state after the
unclean power removal that neither an esptool-driven reset nor a reflash
cleared. Consistent with known ESP32-C6 USB-serial-jtag quirks where the
USB peripheral's state survives a software/RTS reset because it's tied to
the USB host connection, not the chip reset domain.
Fix: a full PHYSICAL power cycle - unplug the USB cable, wait ~5s, plug
back in - brought the board straight back to life (normal boot, BLE
advertising, the phone paired immediately). A software reset (esptool
`--after hard_reset`) and a reflash both failed to recover it; only
removing and restoring bus power did.
Status: RESOLVED (2026-07-12) via physical replug. Flagged for the 30-day
soak: a real-world power blip or brownout could plausibly wedge the board
the same way, and it would then sit silent (not capturing, not
advertising) until physically power-cycled - which a shop owner might not
know to do. Worth watching for during the soak, and a candidate argument
for a hardware watchdog/auto-recovery path or a cleaner power arrangement
before a real pilot.

## [FIRMWARE] ESP-IDF 5.3.2 toolchain needed a manual reinstall to build/flash
Date: 2026-07-15
Problem: reflashing the hold-to-restart change, `export.ps1` for
esp-idf-v5.3.2 reported `tool idf-exe / dfu-util / esp-rom-elfs has no
installed versions`, then `idf.py` wasn't on PATH; after installing those,
export failed again with `python_env\idf5.3_py3.11_env\...\python.exe
doesn't exist`; and once that was fixed, `idf.py build` refused with the
project "configured with 'C:\Espressif\python_env\...'" vs the now-active
`C:\Users\norke\.espressif\python_env\...` and told me to `fullclean`.
Root cause: the machine's IDF install was half-populated and, more
importantly, `IDF_TOOLS_PATH` was inconsistent between whoever configured
`firmware/build/` previously (`C:\Espressif`) and this session
(`C:\Users\norke\.espressif`). ESP-IDF records the exact python path in
the build tree, so switching IDF_TOOLS_PATH invalidates an existing
build/ until a fullclean.
Fix (repeatable recipe for this machine): with
`IDF_PATH=C:\Espressif\frameworks\esp-idf-v5.3.2` and
`IDF_TOOLS_PATH=C:\Users\norke\.espressif`, run
`C:\Espressif\tools\idf-python\3.11.2\python.exe <IDF_PATH>\tools\idf_tools.py install`
then the same with `install-python-env`, then source `export.ps1`, then
`idf.py fullclean` before `idf.py build`. Keep IDF_TOOLS_PATH pinned to
`C:\Users\norke\.espressif` from now on so the recorded python path stops
drifting. dev_cycle.py's serial capture needs pyserial, which the system
python lacks - run it via the IDF venv python
(`C:\Users\norke\.espressif\python_env\idf5.3_py3.11_env\Scripts\python.exe`),
not bare `python`. Board flashed clean on COM17 (VID 303A / PID 1001)
after this; boot verified, real capture resumed (`active=1 obs=6 wl=14
dropped=0`), and the wallclock was already correct (20260715) within ~30s
of boot - the phone auto-reconnected and TIME_SYNC'd on its own after the
reset, confirming the 2026-07-11 reconnect-on-drop fix also covers a
reflash.
Status: RESOLVED (2026-07-15)

## [FIRMWARE] hold-to-restart never reached 10s on a marginal button contact
Date: 2026-07-15
Problem: after flashing the hold-to-restart gesture, holding the button
did nothing for 20s+ (no reboot, no LED countdown). A short click also
did nothing (no cyan pairing blink). Then, after reseating the breadboard
wiring, holding produced a "police" red/blue flicker but still never
rebooted.
Root cause: two compounding issues. (1) Hardware - the tact switch on the
breadboard (GPIO2, active-low, internal pull-up) had a marginal/intermittent
contact after a USB replug, so `gpio_get_level(PIN_BTN)` flickered between
pressed and released while held. (2) Firmware - `ui_task`'s button handler
zeroed `press_started` on ANY single "released" tick, so each flicker
restarted the hold counter from 0. The counter therefore bounced up past
`RESTART_WARN_MS` (5s, red LED override) then reset to idle (blue) over and
over - exactly the "red/blue police blink" the user saw - and never
accumulated a continuous 10s, so `esp_restart()` never fired. The 3s arm
and short click had survived on this same imperfect contact before only
because their windows are short enough to occasionally clear without a
flicker; 10s never did.
Fix: added release debouncing in `ui_task` (`RELEASE_DEBOUNCE_MS` = 100ms).
The press is only considered ended once the raw pin reads high continuously
for the debounce window; a briefer high blip is ignored and the hold
counter keeps accumulating through it. Short-click length is measured to
the first release edge (`release_since - press_started`), not to the
debounced end, so click timing is unaffected. This makes the arm/restart
gestures robust to a bouncy contact instead of silently never completing.
The user still needs to firm up / replace the physical switch for a clean
contact - the debounce buys margin against brief bounce, not against a
switch that's open for >100ms at a time.
Status: OPEN - firmware fix built and flashed (2026-07-15); pending
hands-on confirmation that a 10s hold now reboots with the reseated switch.
