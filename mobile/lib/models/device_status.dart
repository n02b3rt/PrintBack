/// Mirrors the BLE STATUS characteristic JSON (docs/DATA_MODEL.md,
/// firmware/main/ble_gatt.c `gatt_status_read`), e.g.
/// `{"fw":"5563585","sd_ok":true,"sd_free_mb":431,"uptime_s":168,"heap":115856,"reset":"poweron","wl":14}`.
/// A read-only health snapshot of the device - firmware version, SD card
/// state, uptime, free heap, last reset reason, whitelist size. No
/// per-client data (`wl` is a count only, never a fingerprint).
class DeviceStatus {
  final String fw;
  final bool sdOk;
  final int sdFreeMb;
  final int uptimeS;
  final int heap;
  final String reset;

  /// Total whitelist size (auto-whitelisted background devices + any
  /// manually armed). Null on firmware predating the `wl` STATUS field, so
  /// the UI can hide the row rather than show a fake 0.
  final int? whitelistCount;

  const DeviceStatus({
    required this.fw,
    required this.sdOk,
    required this.sdFreeMb,
    required this.uptimeS,
    required this.heap,
    required this.reset,
    this.whitelistCount,
  });

  /// Tolerant of missing/renamed fields - a slightly older firmware that
  /// omits a key should degrade to a sensible default, not throw.
  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    return DeviceStatus(
      fw: json['fw'] as String? ?? '?',
      sdOk: json['sd_ok'] as bool? ?? false,
      sdFreeMb: (json['sd_free_mb'] as num?)?.toInt() ?? 0,
      uptimeS: (json['uptime_s'] as num?)?.toInt() ?? 0,
      heap: (json['heap'] as num?)?.toInt() ?? 0,
      reset: json['reset'] as String? ?? 'unknown',
      whitelistCount: (json['wl'] as num?)?.toInt(),
    );
  }
}
