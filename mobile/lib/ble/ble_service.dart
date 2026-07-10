import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/aggregate.dart';
import '../models/device_config.dart';

/// UUIDs from docs/DATA_MODEL.md "BLE GATT service and characteristic UUIDs".
class PrintBackUuids {
  static final service = Guid('e794a7d8-6905-4552-b7a2-d0cdc9dae0f6');
  static final stats = Guid('1b1465c2-296e-4acd-b544-ba1a30ed7f13');
  static final config = Guid('c5468eed-52a8-434b-bc6f-0d60c323f07f');
  static final timeSync = Guid('5ebb01c3-8110-4ace-b139-436c1fa0b81f');
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
  StreamSubscription<List<int>>? _statsSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final _statsController = StreamController<Aggregate>.broadcast();
  Stream<Aggregate> get statsUpdates => _statsController.stream;

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  BluetoothConnectionState get connectionState => _connectionState;

  BluetoothDevice? get device => _device;

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

  /// Connects, discovers the PrintBack service, writes the current wall
  /// clock to TIME_SYNC (docs/DECISIONS.md D6 - "on every connection", not
  /// just first pairing), then subscribes to STATS notifications.
  Future<void> connect(BluetoothDevice device) async {
    if (!await requestPermissions()) {
      throw StateError('Bluetooth permission not granted');
    }
    _device = device;
    await device.connect(mtu: null);

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      _connectionState = state;
      notifyListeners();
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

    await _writeTimeSync();

    await _statsChr!.setNotifyValue(true);
    await _statsSub?.cancel();
    _statsSub = _statsChr!.lastValueStream.listen(_onStatsNotification);

    notifyListeners();
  }

  /// Subscribing only gets *future* notifications (next hour/day rollover
  /// on the device) - there's no history replay on connect
  /// (docs/DATA_MODEL.md "Backfill after a longer gap" was never built,
  /// see docs/PROGRESS.md). A plain read of STATS returns "today so far"
  /// (gatt_stats_read() in firmware/main/ble_gatt.c reads stats/today.bin),
  /// so callers (the dashboard, right after connecting) can show something
  /// immediately instead of sitting at 0/0 until the next rollover fires.
  /// A pull, not a push through statsUpdates, deliberately - a screen
  /// calling this in initState() would otherwise race the broadcast
  /// stream (connect() already finished and could've emitted before the
  /// screen even subscribes).
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

  Future<void> _writeTimeSync() async {
    final unixSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final bytes = ByteData(4)
      ..setUint32(0, unixSeconds, Endian.little);
    await _timeSyncChr!.write(bytes.buffer.asUint8List());
  }

  void _onStatsNotification(List<int> value) {
    if (value.isEmpty) return;
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
    await _statsSub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _statsChr = null;
    _configChr = null;
    _timeSyncChr = null;
    _device = null;
    _connectionState = BluetoothConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    _connSub?.cancel();
    _statsController.close();
    super.dispose();
  }
}
