import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_service.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';

/// Synthetic footfall for showing the app without a device - a sales demo, a
/// screenshot, a store listing.
///
/// Deliberately imitates the real thing's *limitations*, not just its shape:
/// hourly detail exists only for the last week (the device backfills no more
/// than that) and hours under the k-anonymity threshold are missing entirely,
/// exactly as they would be in the field. A demo that looks better than the
/// product teaches the wrong expectations.
///
/// Deterministic: the same day always generates the same numbers, so a demo
/// doesn't reshuffle itself between screenshots.
class DemoData {
  DemoData._();

  /// Device id the demo rows are filed under. Not a Bluetooth address, so it
  /// can never collide with a real device's rows.
  static const deviceId = 'printback-demo';

  /// Typical visitors by weekday (0=Monday) - a small shop's week, quiet
  /// start, busy Saturday, dead Sunday.
  static const _byWeekday = [40, 45, 50, 55, 70, 90, 25];

  /// Rough share of the day's visitors arriving in each hour 8..20.
  static const _hourShape = [
    0.03, 0.05, 0.07, 0.09, 0.11, 0.12, 0.11, 0.09, 0.08, 0.08, 0.07, 0.06, 0.04
  ];
  static const _firstHour = 8;

  /// How far back hourly detail goes, matching the device's own backfill
  /// (docs/DATA_MODEL.md).
  static const _hourlyDays = 7;

  /// k-anonymity threshold - hours under it never leave the device, so the
  /// demo must not show them either.
  static const _kanonMin = 5;

  /// Stable pseudo-random in [0,1) from a date and a salt (FNV-1a-ish). Not
  /// cryptography - just repeatable jitter.
  static double _noise(String seed, int salt) {
    var h = 2166136261;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 16777619) & 0x7fffffff;
    }
    h = ((h ^ salt) * 16777619) & 0x7fffffff;
    return (h % 1000) / 1000.0;
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// [days] days of daily rows ending at [today], plus hourly rows for the
  /// last [_hourlyDays] of them.
  static List<Aggregate> generate({required DateTime today, int days = 60}) {
    final out = <Aggregate>[];
    final base = DateTime(today.year, today.month, today.day);

    for (var i = days - 1; i >= 0; i--) {
      final d = base.subtract(Duration(days: i));
      final date = _date(d);
      final weekday = d.weekday - 1; // DateTime: 1=Mon
      final jitter = 0.8 + _noise(date, 1) * 0.4; // +/-20%
      final unique = (_byWeekday[weekday] * jitter).round();
      final returning =
          (unique * (0.30 + _noise(date, 2) * 0.15)).round().clamp(0, unique);

      out.add(Aggregate(
        date: date,
        hour: null,
        unique: unique,
        returning: returning,
        kanon: false,
      ));

      if (i < _hourlyDays) {
        for (var h = 0; h < _hourShape.length; h++) {
          final hu = (unique * _hourShape[h] * (0.85 + _noise(date, h + 10) * 0.3))
              .round();
          // Under the threshold the device publishes nothing at all - so
          // neither do we. This is what puts the honest gaps in the chart.
          if (hu < _kanonMin) continue;
          out.add(Aggregate(
            date: date,
            hour: _firstHour + h,
            unique: hu,
            returning: (hu * 0.3).round(),
            kanon: false,
          ));
        }
      }
    }
    return out;
  }

  /// Remembers which real device was active before demo mode took over, so
  /// leaving demo puts the operator back where they were instead of dumping
  /// them at the pairing screen with their device apparently gone.
  static const _previousDeviceKey = 'demo_previous_device_id';

  /// Fills the cache with demo rows and points the app at them. The app then
  /// runs in its ordinary offline mode - no special-casing in the screens.
  static Future<void> enable(BleService ble, {DateTime? today}) async {
    final previous = ble.activeDeviceId;
    final prefs = await SharedPreferences.getInstance();
    if (previous != null && previous != deviceId) {
      await prefs.setString(_previousDeviceKey, previous);
    }

    final db = LocalDb();
    await db.deleteDevice(deviceId);
    for (final a in generate(today: today ?? DateTime.now())) {
      await db.upsert(deviceId, a);
    }
    await ble.setActiveDeviceId(deviceId);
  }

  /// Drops the demo rows and restores whatever device was active before -
  /// or, if there wasn't one, leaves the app at pairing. The real device was
  /// never unpaired (demo only ever swapped the active id), so this is just
  /// putting the pointer back.
  static Future<void> disable(BleService ble) async {
    await LocalDb().deleteDevice(deviceId);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_previousDeviceKey);
    await prefs.remove(_previousDeviceKey);
    await ble.setActiveDeviceId(previous);
  }

  static bool isDemo(String? deviceId) => deviceId == DemoData.deviceId;
}
