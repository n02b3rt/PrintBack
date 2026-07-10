/// Mirrors the BLE CONFIG JSON payload (docs/DATA_MODEL.md). Both fields
/// are required on every write - the device rejects a partial payload.
class DeviceConfig {
  final int rssiFloor;
  final int returningWindowDays;

  const DeviceConfig({
    required this.rssiFloor,
    required this.returningWindowDays,
  });

  factory DeviceConfig.fromJson(Map<String, dynamic> json) {
    return DeviceConfig(
      rssiFloor: json['rssi_floor'] as int,
      returningWindowDays: json['returning_window_days'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rssi_floor': rssiFloor,
      'returning_window_days': returningWindowDays,
    };
  }
}
