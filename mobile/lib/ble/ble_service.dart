import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

  Stream<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) {
    FlutterBluePlus.startScan(
      withServices: [PrintBackUuids.service],
      timeout: timeout,
    );
    return FlutterBluePlus.scanResults;
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// Connects, discovers the PrintBack service, writes the current wall
  /// clock to TIME_SYNC (docs/DECISIONS.md D6 - "on every connection", not
  /// just first pairing), then subscribes to STATS notifications.
  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await device.connect(mtu: null);

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      _connectionState = state;
      notifyListeners();
    });

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await device.requestMtu(185);
    }

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.serviceUuid == PrintBackUuids.service,
      orElse: () =>
          throw StateError('PrintBack GATT service not found on device'),
    );

    _statsChr = service.characteristics
        .firstWhere((c) => c.characteristicUuid == PrintBackUuids.stats);
    _configChr = service.characteristics
        .firstWhere((c) => c.characteristicUuid == PrintBackUuids.config);
    _timeSyncChr = service.characteristics
        .firstWhere((c) => c.characteristicUuid == PrintBackUuids.timeSync);

    await _writeTimeSync();

    await _statsChr!.setNotifyValue(true);
    await _statsSub?.cancel();
    _statsSub = _statsChr!.lastValueStream.listen(_onStatsNotification);

    notifyListeners();
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
