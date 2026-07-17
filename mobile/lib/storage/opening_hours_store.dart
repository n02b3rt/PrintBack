import 'package:shared_preferences/shared_preferences.dart';

import '../logic/opening_hours.dart';

/// Persists the shop's week.
///
/// Stored as three parallel 7-entry lists rather than one encoded blob: it's
/// a handful of ints, and keeping them as plain prefs means a future change
/// to the model can migrate them by reading the parts, instead of parsing a
/// format we invented. Older installs (a single week-wide range, before
/// per-weekday hours existed) fall through to the defaults - the setting is
/// two taps to redo and silently mis-restoring someone's hours would be
/// worse than asking.
class OpeningHoursStore {
  static const _enabled = 'opening_hours_enabled';
  static const _closed = 'opening_hours_closed_v2';
  static const _open = 'opening_hours_open_v2';
  static const _close = 'opening_hours_close_v2';
  static const _advanced = 'opening_hours_advanced';

  /// Whether the operator chose the per-day editor. Purely a UI preference -
  /// the model is per-day either way, the simple view just writes the same
  /// hours to every open day.
  static Future<bool> loadAdvanced() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_advanced) ?? false;
  }

  static Future<void> saveAdvanced(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_advanced, value);
  }

  static Future<OpeningHours> load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabled) ?? false;
    final closed = prefs.getStringList(_closed);
    final open = prefs.getStringList(_open);
    final close = prefs.getStringList(_close);

    if (closed == null || open == null || close == null ||
        closed.length != 7 || open.length != 7 || close.length != 7) {
      return OpeningHours(enabled: enabled, days: OpeningHours.defaults.days);
    }

    return OpeningHours(
      enabled: enabled,
      days: [
        for (var i = 0; i < 7; i++)
          DaySchedule(
            closed: closed[i] == '1',
            openHour: int.tryParse(open[i]) ?? 8,
            closeHour: int.tryParse(close[i]) ?? 20,
          ),
      ],
    );
  }

  static Future<void> save(OpeningHours hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabled, hours.enabled);
    await prefs.setStringList(
        _closed, [for (final d in hours.days) d.closed ? '1' : '0']);
    await prefs.setStringList(
        _open, [for (final d in hours.days) '${d.openHour}']);
    await prefs.setStringList(
        _close, [for (final d in hours.days) '${d.closeHour}']);
  }
}
