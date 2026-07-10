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
