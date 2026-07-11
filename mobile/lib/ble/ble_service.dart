import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/aggregate.dart';
import '../models/device_config.dart';

const _activeDeviceIdKey = 'active_device_id';

/// UUIDs from docs/DATA_MODEL.md "BLE GATT service and characteristic UUIDs".
class PrintBackUuids {
  static final service = Guid('e794a7d8-6905-4552-b7a2-d0cdc9dae0f6');
  static final stats = Guid('1b1465c2-296e-4acd-b544-ba1a30ed7f13');
  static final config = Guid('c5468eed-52a8-434b-bc6f-0d60c323f07f');
  static final timeSync = Guid('5ebb01c3-8110-4ace-b139-436c1fa0b81f');
  static final sync = Guid('8f2c1e40-7bb5-4b9f-9e11-3c6b9d5a2f77');
}

/// Talks to exactly one PrintBack device's BLE GATT server. Pairing itself
/// (bonding) is handled by the OS after the physical button press on the
/// device (docs/DECISIONS.md D5) - this class only drives the GATT
/// characteristics once a connection exists.
class BleService extends ChangeNotifier {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _statsChr;
  BluetoothCharacteristic? _configChr;
  BluetoothCharacteristic? _timeSyncChr;
  BluetoothCharacteristic? _syncChr;
  StreamSubscription<List<int>>? _statsSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final _statsController = StreamController<Aggregate>.broadcast();
  Stream<Aggregate> get statsUpdates => _statsController.stream;

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  BluetoothConnectionState get connectionState => _connectionState;

  BluetoothDevice? get device => _device;

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

  /// Retries once, after a short settle delay, when the BLE link drops
  /// unexpectedly (device reflashed/rebooted, walked out of range) -
  /// without this, the app just sits disconnected until the user
  /// manually relaunches it or reconnects via Settings, which also means
  /// the device's clock (no RTC, corrected only by TIME_SYNC on connect,
  /// docs/DECISIONS.md D6) stays stuck on a stale fallback and misdates
  /// everything it captures in the meantime (docs/LEARNINGS.md
  /// 2026-07-11).
  Timer? _reconnectTimer;

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

  /// All PrintBack devices the OS currently knows about (bonded, or
  /// recently connected by any app on this phone) - a live query, not a
  /// list we maintain ourselves, so it can never drift from what's
  /// actually bonded. Used by Settings' device switcher.
  Future<List<BluetoothDevice>> knownDevices() {
    return FlutterBluePlus.systemDevices([PrintBackUuids.service]);
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

    List<BluetoothDevice> candidates;
    try {
      candidates = await knownDevices();
    } catch (_) {
      candidates = [];
    }

    final prefs = await SharedPreferences.getInstance();
    final preferredId = prefs.getString(_activeDeviceIdKey);
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

      await _statsChr!.setNotifyValue(true);
      await _statsSub?.cancel();
      _statsSub = _statsChr!.lastValueStream.listen(_onStatsNotification);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeDeviceIdKey, device.remoteId.str);

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
      return Aggregate.fromJson(map);
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

  /// One retry, after a short delay to let the device's BLE stack come
  /// back up (e.g. mid-reboot after a reflash) rather than hammering it
  /// immediately. Reuses tryAutoConnect() rather than reconnecting to
  /// [device] directly: it already prefers the last-connected device (the
  /// one that just dropped) via the same SharedPreferences key connect()
  /// writes on every success, so this naturally retries the right device
  /// first without duplicating that logic. Deliberately just one retry,
  /// not a backoff loop - if it fails, the device is genuinely
  /// unreachable and the manual pairing screen is the right fallback,
  /// same as any other tryAutoConnect() failure.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      tryAutoConnect();
    });
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

  void _onStatsNotification(List<int> value) {
    if (value.isEmpty) return;
    // Every row that arrives while a sync is in flight pushes the "done"
    // deadline back - a big backlog replay is many notifications in a
    // row, not one.
    if (_isSyncing) _armSyncIdleTimer();
    try {
      final map = jsonDecode(utf8.decode(value)) as Map<String, dynamic>;
      _statsController.add(Aggregate.fromJson(map));
    } catch (_) {
      // Malformed or mid-fragment notification: drop it, the next
      // notification carries the next row (docs/DATA_MODEL.md never
      // batches, so nothing besides this one row is lost).
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

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _statsSub?.cancel();
    await _connSub?.cancel();
    _syncIdleTimer?.cancel();
    await _device?.disconnect();
    _statsChr = null;
    _configChr = null;
    _timeSyncChr = null;
    _syncChr = null;
    _device = null;
    _isSyncing = false;
    _connectionState = BluetoothConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    _connSub?.cancel();
    _syncIdleTimer?.cancel();
    _reconnectTimer?.cancel();
    _statsController.close();
    super.dispose();
  }
}
