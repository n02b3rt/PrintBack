import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/aggregate.dart';
import '../models/device_config.dart';
import '../models/device_status.dart';
import '../storage/local_db.dart';

const _activeDeviceIdKey = 'active_device_id';
const _knownDevicesKey = 'known_printback_devices';

/// One entry in the app's own registry of devices it has actually
/// connected to and verified as a PrintBack (all four characteristics
/// present). Unlike the OS bonded-device list, this can never contain an
/// unrelated watch or band (docs/LEARNINGS.md 2026-07-10).
typedef KnownDevice = ({String id, String name});

/// UUIDs from docs/DATA_MODEL.md "BLE GATT service and characteristic UUIDs".
class PrintBackUuids {
  static final service = Guid('e794a7d8-6905-4552-b7a2-d0cdc9dae0f6');
  static final stats = Guid('1b1465c2-296e-4acd-b544-ba1a30ed7f13');
  static final config = Guid('c5468eed-52a8-434b-bc6f-0d60c323f07f');
  static final timeSync = Guid('5ebb01c3-8110-4ace-b139-436c1fa0b81f');
  static final sync = Guid('8f2c1e40-7bb5-4b9f-9e11-3c6b9d5a2f77');
  static final status = Guid('cf2c77c3-71e7-4121-a695-e22fdbcbe4ba');
}

/// Talks to exactly one PrintBack device's BLE GATT server. Pairing itself
/// (bonding) is handled by the OS after the physical button press on the
/// device (docs/DECISIONS.md D5) - this class only drives the GATT
/// characteristics once a connection exists.
class BleService extends ChangeNotifier with WidgetsBindingObserver {
  BleService() {
    WidgetsBinding.instance.addObserver(this);
    _loadActiveDeviceId();
  }

  BluetoothDevice? _device;
  BluetoothCharacteristic? _statsChr;
  BluetoothCharacteristic? _configChr;
  BluetoothCharacteristic? _timeSyncChr;
  BluetoothCharacteristic? _syncChr;
  BluetoothCharacteristic? _statusChr;
  StreamSubscription<List<int>>? _statsSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final _statsController = StreamController<Aggregate>.broadcast();
  Stream<Aggregate> get statsUpdates => _statsController.stream;

  final _localDb = LocalDb();

  /// Writes an incoming aggregate to the local cache. This lives in the
  /// service, not in a screen's `statsUpdates` listener, because
  /// [statsUpdates] is a broadcast stream: anything emitted while no screen
  /// happens to be subscribed (during connect(), before HomeShell mounts,
  /// mid-reconnect) is dropped on the floor and would never reach the db.
  /// That showed up as the numbers quietly changing after an app restart -
  /// the next SYNC replayed exactly the rows that had been lost. Persisting
  /// at the point of arrival makes the cache independent of whatever UI is
  /// on screen; the stream is then only a "something changed, redraw" hint.
  Future<void> _persist(Aggregate agg) async {
    final deviceId = _activeDeviceId;
    if (deviceId == null) return;
    try {
      await _localDb.upsert(deviceId, agg);
    } catch (e) {
      debugPrint('local cache write failed: $e');
    }
  }

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  BluetoothConnectionState get connectionState => _connectionState;

  /// A connection that's not just linked but fully verified as ours -
  /// characteristics discovered. The raw [connectionState] briefly reads
  /// `connected` during an attempt on a wrong device (e.g. a bonded watch)
  /// before discovery fails and drops it; gating UI on this instead avoids
  /// the banner flashing "connected" mid-attempt.
  bool get isConnectedReady =>
      _connectionState == BluetoothConnectionState.connected &&
      _statsChr != null;

  BluetoothDevice? get device => _device;

  /// The remoteId of the device the user is currently working with, whether
  /// or not a live connection exists right now. Loaded from the persisted
  /// `active_device_id` at startup and updated on every successful
  /// connect(), so the dashboard/statistics screens can read this device's
  /// cached aggregates offline instead of crashing on `device!` when
  /// nothing is connected (the whole point of offline mode). Null only
  /// before the very first successful pairing.
  String? _activeDeviceId;
  String? get activeDeviceId => _activeDeviceId;

  Future<void> _loadActiveDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    _activeDeviceId = prefs.getString(_activeDeviceIdKey);
    notifyListeners();
  }

  /// True from the moment requestSync() is called until ~1.5s pass with
  /// no new STATS notification arriving - the same "quiet period means
  /// done" heuristic the wire protocol itself uses (docs/DATA_MODEL.md
  /// "BLE SYNC payload" - there's no explicit completion marker). Lets
  /// the UI show a real "syncing..." state instead of firing a write and
  /// going silent.
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  DateTime? _lastSyncCompleted;
  DateTime? get lastSyncCompleted => _lastSyncCompleted;

  Timer? _syncIdleTimer;

  /// Auto-reconnect after the BLE link drops unexpectedly (device
  /// reflashed/rebooted, walked out of range) - without this the app sits
  /// disconnected until the user relaunches it or reconnects via Settings,
  /// which also leaves the device's clock stuck on a stale fallback
  /// (no RTC, corrected only by TIME_SYNC on connect, docs/DECISIONS.md D6)
  /// misdating everything it captures meanwhile (docs/LEARNINGS.md
  /// 2026-07-11). Retries on a growing backoff so a device that's simply
  /// out of range for a while doesn't get hammered.
  Timer? _reconnectTimer;

  /// Growing delay between auto-reconnect attempts; caps at the last entry.
  static const _reconnectBackoff = [
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  int _reconnectAttempt = 0;

  bool _isReconnecting = false;
  bool get isReconnecting => _isReconnecting;

  /// App foreground/background, so the reconnect loop only runs while the
  /// app is actually in use - retrying BLE in the background would drain
  /// the battery for no benefit (nothing's watching the data).
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Guards connect() against running twice concurrently - a manual retry
  /// racing _scheduleReconnect()'s auto-reconnect (or two reconnect timers
  /// overlapping after repeated drops) issues two GATT writeCharacteristic
  /// calls on the same connection at once, which Android's stack answers
  /// with ERROR_GATT_WRITE_REQUEST_BUSY or a 15s timeout instead of a clean
  /// result (docs/LEARNINGS.md 2026-07-11 "connect/disconnect churn").
  bool _connecting = false;

  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  /// Android 12+ (API 31+) treats BLE scan/connect as runtime-requestable
  /// "dangerous" permissions - declaring them in AndroidManifest.xml alone
  /// isn't enough, flutter_blue_plus doesn't request them on our behalf,
  /// and startScan() throws a PlatformException without one. iOS instead
  /// prompts automatically off the Info.plist usage string on first BLE
  /// use, no explicit request needed there.
  Future<bool> requestPermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// Ensures the Bluetooth adapter is on, popping the Android system
  /// "turn on Bluetooth?" one-tap dialog if it's off (much better than a
  /// dead "can't connect" - the user asked for exactly this). Returns
  /// whether the adapter ends up on. On iOS the adapter can't be enabled
  /// programmatically, so this just reports the current state and the UI
  /// tells the user to enable it themselves.
  Future<bool> ensureAdapterOn() async {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
      return true;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await FlutterBluePlus.turnOn();
      return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
    } catch (_) {
      // User declined the dialog or it timed out.
      return false;
    }
  }

  Future<void> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!await requestPermissions()) {
      throw StateError('Bluetooth permission not granted');
    }
    await FlutterBluePlus.startScan(
      withServices: [PrintBackUuids.service],
      timeout: timeout,
    );
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// Candidate devices the OS knows about (bonded, or recently connected
  /// by any app) - a best-effort list used only as *input* to
  /// tryAutoConnect(), which validates each before trusting it. Not shown
  /// in the UI: on Android this can return an unrelated bonded watch/band
  /// (docs/LEARNINGS.md 2026-07-10), so Settings uses the verified
  /// registry (knownPrintBackDevices()) instead.
  Future<List<BluetoothDevice>> knownDevices() {
    return FlutterBluePlus.systemDevices([PrintBackUuids.service]);
  }

  /// The app's own registry of devices it has actually connected to and
  /// verified as PrintBacks. Backs the Settings device switcher, so it can
  /// never list a stranger's watch. Also works offline (no BT query
  /// needed), unlike systemDevices().
  Future<List<KnownDevice>> knownPrintBackDevices() async {
    final prefs = await SharedPreferences.getInstance();
    return _readRegistry(prefs);
  }

  List<KnownDevice> _readRegistry(SharedPreferences prefs) {
    final raw = prefs.getString(_knownDevicesKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          (id: (e as Map)['id'] as String, name: e['name'] as String),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Records a just-verified device in the registry (upsert by id, so a
  /// reconnect refreshes its name without duplicating). Called from
  /// connect() only after the full characteristic lookup succeeded, which
  /// is the proof it's really a PrintBack.
  Future<void> _recordVerifiedDevice(BluetoothDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _readRegistry(prefs);
    final id = device.remoteId.str;
    final name = device.platformName.isNotEmpty ? device.platformName : id;
    final updated = [
      (id: id, name: name),
      ...entries.where((e) => e.id != id),
    ];
    await prefs.setString(
      _knownDevicesKey,
      jsonEncode([for (final e in updated) {'id': e.id, 'name': e.name}]),
    );
  }

  /// Looks for an already-bonded PrintBack device, preferring a quick
  /// systemDevices() lookup (much faster than an active scan) and
  /// connects to it. Prefers the device the user last successfully
  /// connected to, if it's among the ones found. Returns null - never
  /// throws - if nothing's found or every attempt fails, so callers can
  /// fall back to the manual pairing screen without treating "no device
  /// nearby yet" as an error.
  ///
  /// Tries every systemDevices() candidate in order, not just the first:
  /// on Android, `systemDevices(withServices: ...)` can't actually check
  /// GATT services on a bonded-but-not-yet-connected device (that needs a
  /// live connection), so the service filter is best-effort and the list
  /// can include unrelated bonded devices, or miss the real one entirely
  /// (confirmed on hardware, twice - one run returned an unrelated bonded
  /// device first, another run returned ONLY the unrelated device, not
  /// ours at all). connect() already throws if STATS/CONFIG/TIME_SYNC/SYNC
  /// aren't all found, which doubles as the real "is this actually our
  /// device" check - reused here instead of duplicating it. If every
  /// systemDevices() candidate fails (including the "found nothing"
  /// case), falls back to a real 5s scan filtered by the service UUID the
  /// firmware actually broadcasts over the air - authoritative in a way
  /// the OS's bonded-device cache isn't, see _scanAndConnect().
  Future<BluetoothDevice?> tryAutoConnect() async {
    if (!await requestPermissions()) return null;

    final prefs = await SharedPreferences.getInstance();
    final preferredId = prefs.getString(_activeDeviceIdKey);

    // First try the app's own registry of verified PrintBacks: those ids
    // are proven to be our device, so we never even attempt a connection
    // to an unrelated bonded device (e.g. the user's watch) - which is
    // both faster and avoids the connect/drop flicker that a wrong-device
    // attempt causes (docs/LEARNINGS.md 2026-07-10). Last-used first.
    final registry = await knownPrintBackDevices();
    final registryOrdered = [
      ...registry.where((d) => d.id == preferredId),
      ...registry.where((d) => d.id != preferredId),
    ];
    for (final entry in registryOrdered) {
      try {
        final device = BluetoothDevice.fromId(entry.id);
        await connect(device);
        return device;
      } catch (_) {
        continue;
      }
    }

    // Fall back to the OS candidate list only if the registry is empty or
    // its devices are all unreachable (e.g. first launch after install, or
    // the device is powered off).
    List<BluetoothDevice> candidates;
    try {
      candidates = await knownDevices();
    } catch (_) {
      candidates = [];
    }

    final ordered = [
      ...candidates.where((d) => d.remoteId.str == preferredId),
      ...candidates.where((d) => d.remoteId.str != preferredId),
    ];

    for (final candidate in ordered) {
      try {
        await connect(candidate);
        return candidate;
      } catch (_) {
        continue;
      }
    }

    // systemDevices() is best-effort on Android for bonded-but-not-connected
    // devices and can come back with only an unrelated bonded device, or
    // none at all (confirmed on hardware: a phone with two bonded BLE
    // devices got only the wrong one back, so the loop above never even
    // saw the real one). A real scan filters by the service UUID actually
    // broadcast over the air by the firmware (docs/LEARNINGS.md BLE
    // advertisement split), which is authoritative in a way the OS's
    // bonded-device cache isn't - falls back to it instead of giving up
    // and forcing the user to the manual pairing screen every time.
    return _scanAndConnect();
  }

  Future<BluetoothDevice?> _scanAndConnect() async {
    final found = Completer<BluetoothDevice>();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      if (results.isNotEmpty && !found.isCompleted) {
        found.complete(results.first.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [PrintBackUuids.service],
        timeout: const Duration(seconds: 5),
      );
      final device = await found.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('no device found'),
      );
      await FlutterBluePlus.stopScan();
      await connect(device);
      return device;
    } catch (_) {
      await FlutterBluePlus.stopScan();
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// Connects, discovers the PrintBack service, writes the current wall
  /// clock to TIME_SYNC (docs/DECISIONS.md D6 - "on every connection", not
  /// just first pairing), then subscribes to STATS notifications.
  Future<void> connect(BluetoothDevice device) async {
    if (_connecting) {
      throw StateError('connect() already in progress');
    }
    _connecting = true;
    try {
      if (!await requestPermissions()) {
        throw StateError('Bluetooth permission not granted');
      }
      _reconnectTimer?.cancel();
      if (_device != null && _device!.remoteId != device.remoteId) {
        await disconnect();
      }
      _device = device;
      await device.connect(mtu: null);

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        _connectionState = state;
        notifyListeners();
        // disconnect() below cancels _connSub before calling
        // device.disconnect(), so a disconnected event that actually
        // reaches this listener is never self-initiated - it's the link
        // dropping out from under us (device reflashed/rebooted, walked
        // out of range).
        if (state == BluetoothConnectionState.disconnected) {
          _scheduleReconnect();
        }
      });

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await device.requestMtu(185);
        // Android caches a device's GATT table by Bluetooth address across
        // connections. During firmware development the same physical device
        // gets new characteristics added between flashes (e.g. TIME_SYNC in
        // this phase) while keeping the same address, so a stale cache can
        // hide them from discoverServices() below even though the firmware
        // genuinely serves them. Best-effort: a failure here just means
        // discoverServices() falls back to whatever Android already has.
        try {
          await device.clearGattCache();
        } catch (_) {}
      }

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.serviceUuid == PrintBackUuids.service,
        orElse: () =>
            throw StateError('PrintBack GATT service not found on device'),
      );

      _statsChr = service.characteristics.firstWhere(
        (c) => c.characteristicUuid == PrintBackUuids.stats,
        orElse: () => throw StateError('STATS characteristic not found'),
      );
      _configChr = service.characteristics.firstWhere(
        (c) => c.characteristicUuid == PrintBackUuids.config,
        orElse: () => throw StateError('CONFIG characteristic not found'),
      );
      _timeSyncChr = service.characteristics.firstWhere(
        (c) => c.characteristicUuid == PrintBackUuids.timeSync,
        orElse: () => throw StateError('TIME_SYNC characteristic not found'),
      );
      _syncChr = service.characteristics.firstWhere(
        (c) => c.characteristicUuid == PrintBackUuids.sync,
        orElse: () => throw StateError('SYNC characteristic not found'),
      );
      // STATUS is optional - a slightly older firmware without it must
      // still connect (unlike the four above, whose absence means "not our
      // device"). Nullable firstWhere, never throws.
      _statusChr = service.characteristics
          .cast<BluetoothCharacteristic?>()
          .firstWhere((c) => c!.characteristicUuid == PrintBackUuids.status,
              orElse: () => null);

      // First-time bonding: do it explicitly (Android only) before the first
      // encrypted write, rather than letting that write trigger it. Letting
      // the encrypted TIME_SYNC write kick off bonding makes Android show its
      // pairing dialog twice (a documented flutter_blue_plus quirk); an
      // explicit createBond() does it once. Skipped when already bonded so a
      // routine auto-reconnect isn't touched. Best-effort: any failure falls
      // through to the old implicit-bond path below.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        try {
          final bond = await device.bondState.first.timeout(
              const Duration(seconds: 2),
              onTimeout: () => BluetoothBondState.none);
          if (bond != BluetoothBondState.bonded) {
            await device.createBond();
          }
        } catch (_) {}
      }

      // TIME_SYNC requires an encrypted link (BLE_GATT_CHR_F_WRITE_ENC,
      // firmware/main/ble_gatt.c) and is the first write issued right after
      // reconnecting to an already-bonded device. Android reports the link
      // "connected" as soon as the basic connection forms, but re-encrypting
      // with an already-bonded peer is a separate, slightly later step -
      // writing before that settles has reproducibly torn down the whole
      // connection (CONNECTION_TERMINATED_BY_LOCAL_HOST) instead of
      // returning a clean GATT error (docs/LEARNINGS.md 2026-07-11). A short
      // settle delay plus one retry follows flutter_blue_plus's own
      // documented guidance for this class of Android flakiness ("catch the
      // error and retry" - no 100% fix exists on their side either).
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await _writeTimeSync();
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _writeTimeSync();
      }

      // Set before subscribing, not after: _persist() keys the cache on
      // this, and a notification landing in the gap would be silently
      // dropped for want of a device id.
      _activeDeviceId = device.remoteId.str;

      await _statsChr!.setNotifyValue(true);
      await _statsSub?.cancel();
      _statsSub = _statsChr!.lastValueStream.listen(_onStatsNotification);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeDeviceIdKey, device.remoteId.str);
      // Reaching here means every PrintBack characteristic was found -
      // proof this is really our device, so add it to the verified
      // registry the Settings switcher shows.
      await _recordVerifiedDevice(device);

      // Connected cleanly - reset the auto-reconnect backoff.
      _reconnectAttempt = 0;
      _isReconnecting = false;

      notifyListeners();
    } catch (e) {
      // A failure partway through (permission denied, service/characteristic
      // not found, a write that never completes) used to leave the native
      // GATT connection open and _device pointing at it - a later connect()
      // call (a manual retry, or tryAutoConnect()'s next candidate) could
      // then collide with that orphaned connection instead of starting
      // clean, surfacing as CONNECTION_TERMINATED_BY_LOCAL_HOST on the
      // *new* attempt (docs/LEARNINGS.md 2026-07-11, root cause traced via
      // a native Android BLE log, not the ESP32 side - the disconnect
      // wasn't coming from this class's own disconnect() at all). Tear the
      // partial connection down before rethrowing so every failure leaves
      // the same clean slate a full disconnect() would.
      try {
        await disconnect();
      } catch (_) {}
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// Subscribing only gets *future* notifications (next hour/day rollover
  /// on the device) - it doesn't by itself replay history. A plain read
  /// of STATS returns "today so far" (gatt_stats_read() in
  /// firmware/main/ble_gatt.c reads stats/today.bin), so callers (the
  /// dashboard, right after connecting) can show something immediately
  /// instead of sitting at 0/0 until the next rollover fires or a SYNC
  /// finishes. A pull, not a push through statsUpdates, deliberately - a
  /// screen calling this in initState() would otherwise race the
  /// broadcast stream (connect() already finished and could've emitted
  /// before the screen even subscribes).
  Future<Aggregate?> readCurrentStats() async {
    if (_statsChr == null) return null;
    try {
      final value = await _statsChr!.read();
      if (value.isEmpty) return null;
      final map = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
      final agg = Aggregate.fromJson(map);
      await _persist(agg); // same ownership rule as the notification path
      return agg;
    } catch (_) {
      return null;
    }
  }

  /// Requests a backlog replay of finalized daily aggregates the device
  /// has that this phone might not (docs/DATA_MODEL.md "BLE SYNC
  /// payload"). Results arrive as ordinary STATS notifications on
  /// [statsUpdates] over the following seconds, not as a return value
  /// here - callers already listening to that stream (dashboard,
  /// statistics screen) pick them up automatically. [sinceUnixDay] is
  /// days since 1970-01-01 UTC; 0 means "everything".
  Future<void> requestSync(int sinceUnixDay) async {
    if (_syncChr == null) return;
    _isSyncing = true;
    notifyListeners();
    _armSyncIdleTimer();
    final bytes = ByteData(4)
      ..setUint32(0, sinceUnixDay, Endian.little);
    await _syncChr!.write(bytes.buffer.asUint8List());
  }

  /// Schedules the next auto-reconnect attempt on the backoff schedule.
  /// Foreground-only; each failed attempt lengthens the delay up to the
  /// cap. Reuses tryAutoConnect() (which prefers the last-connected device
  /// and validates it's really ours), and reschedules itself on failure so
  /// a device that comes back into range eventually reconnects on its own.
  void _scheduleReconnect() {
    if (_lifecycle != AppLifecycleState.resumed) return;
    _reconnectTimer?.cancel();
    final delay = _reconnectBackoff[
        _reconnectAttempt.clamp(0, _reconnectBackoff.length - 1)];
    if (!_isReconnecting) {
      _isReconnecting = true;
      notifyListeners();
    }
    _reconnectTimer = Timer(delay, () async {
      _reconnectAttempt++;
      final device = await tryAutoConnect();
      // connect() resets the backoff state on success; if we're still not
      // connected, queue the next (longer) attempt.
      if (device == null) _scheduleReconnect();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _lifecycle == AppLifecycleState.resumed;
    _lifecycle = state;
    if (state != AppLifecycleState.resumed) {
      // Backgrounded: stop retrying (battery), keep the flag so we resume
      // the loop when the app comes back.
      _reconnectTimer?.cancel();
    } else if (!wasResumed && _isReconnecting) {
      // Foregrounded again mid-reconnect - resume the loop immediately.
      _scheduleReconnect();
    }
  }

  void _armSyncIdleTimer() {
    _syncIdleTimer?.cancel();
    _syncIdleTimer = Timer(const Duration(milliseconds: 1500), () {
      _isSyncing = false;
      _lastSyncCompleted = DateTime.now();
      notifyListeners();
    });
  }

  Future<void> _writeTimeSync() async {
    final unixSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final bytes = ByteData(4)
      ..setUint32(0, unixSeconds, Endian.little);
    await _timeSyncChr!.write(bytes.buffer.asUint8List());
  }

  Future<void> _onStatsNotification(List<int> value) async {
    if (value.isEmpty) return;
    final Aggregate agg;
    try {
      final map = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
      agg = Aggregate.fromJson(map);
    } catch (_) {
      // Malformed or mid-fragment notification: drop it, the next
      // notification carries the next row (docs/DATA_MODEL.md never
      // batches, so nothing besides this one row is lost).
      return;
    }
    // The device's end-of-sync marker means the replay is done: finish the
    // sync immediately rather than waiting out the idle timer, and never
    // let the 1970 sentinel reach the db or the charts. The idle timer
    // stays as a fallback for older firmware that doesn't send a marker.
    if (agg.isSyncEndMarker) {
      _completeSyncNow();
      return;
    }
    // Every real row that arrives while a sync is in flight pushes the
    // "done" deadline back - a big backlog replay is many notifications in
    // a row, not one.
    if (_isSyncing) _armSyncIdleTimer();
    // Cache first, announce second: a listener's reload() then always finds
    // the row already in the db.
    await _persist(agg);
    if (!_statsController.isClosed) _statsController.add(agg);
  }

  void _completeSyncNow() {
    _syncIdleTimer?.cancel();
    if (_isSyncing) {
      _isSyncing = false;
      _lastSyncCompleted = DateTime.now();
      notifyListeners();
    }
  }

  /// Reads the device's STATUS snapshot (firmware version, SD state,
  /// uptime, heap, reset reason) - a plain characteristic read, like
  /// readCurrentStats(). Null if the device doesn't expose STATUS (older
  /// firmware) or the read fails, so the UI can just hide the section.
  Future<DeviceStatus?> readStatus() async {
    if (_statusChr == null) return null;
    try {
      final value = await _statusChr!.read();
      if (value.isEmpty) return null;
      final map = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
      return DeviceStatus.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<DeviceConfig> readConfig() async {
    final value = await _configChr!.read();
    final map = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
    return DeviceConfig.fromJson(map);
  }

  Future<void> writeConfig(DeviceConfig config) async {
    final bytes = utf8.encode(jsonEncode(config.toJson()));
    await _configChr!.write(bytes);
  }

  /// Forgets the active device: drops any live connection and clears the
  /// persisted active-device id so the app returns to a fresh, unpaired
  /// state. Does NOT remove the OS-level Bluetooth bond (an app can't -
  /// the user does that in system settings); the UI shows that instruction
  /// separately.
  /// Points the app at a device id (or nothing) without a BLE connection.
  /// Demo mode uses this: it fabricates a device's worth of cached
  /// aggregates, then hands the app the id, and the ordinary offline path
  /// takes over from there - no demo special-casing in the screens.
  /// Unlike [forgetActiveDevice] this touches no OS bond: the demo id isn't
  /// a Bluetooth address and never was paired.
  Future<void> setActiveDeviceId(String? id) async {
    await disconnect();
    _activeDeviceId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_activeDeviceIdKey);
    } else {
      await prefs.setString(_activeDeviceIdKey, id);
    }
    notifyListeners();
  }

  Future<void> forgetActiveDevice() async {
    // Grab the id before disconnect() clears _device. Removing the OS-level
    // bond (Android), not just the app's pref, is what lets a later re-pair
    // start clean - otherwise the phone keeps its half of the bond while the
    // device forgot its half, the exact one-sided-bond deadlock from
    // docs/LEARNINGS.md 2026-07-11. Best-effort: removeBond can fail (or not
    // exist on iOS), in which case the user falls back to system settings.
    final id = _activeDeviceId ?? _device?.remoteId.str;
    await disconnect();
    if (id != null && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await BluetoothDevice.fromId(id).removeBond();
      } catch (_) {}
    }
    _activeDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeDeviceIdKey);
    notifyListeners();
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    // A user-initiated disconnect ends the reconnect loop too - don't keep
    // trying to reconnect to a device the user deliberately dropped.
    _reconnectAttempt = 0;
    _isReconnecting = false;
    await _statsSub?.cancel();
    await _connSub?.cancel();
    _syncIdleTimer?.cancel();
    await _device?.disconnect();
    _statsChr = null;
    _configChr = null;
    _timeSyncChr = null;
    _syncChr = null;
    _statusChr = null;
    _device = null;
    _isSyncing = false;
    _connectionState = BluetoothConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsSub?.cancel();
    _connSub?.cancel();
    _syncIdleTimer?.cancel();
    _reconnectTimer?.cancel();
    _statsController.close();
    super.dispose();
  }
}
