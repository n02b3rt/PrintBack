import 'package:shared_preferences/shared_preferences.dart';

import '../logic/opening_hours.dart';

/// Persists the shop's opening hours. Same SharedPreferences-with-static-
/// helpers shape as onboarding/onboarding_flags.dart, so there's one way
/// small settings are stored in this app rather than two.
class OpeningHoursStore {
  static const _enabled = 'opening_hours_enabled';
  static const _open = 'opening_hours_open';
  static const _close = 'opening_hours_close';

  static Future<OpeningHours> load() async {
    final prefs = await SharedPreferences.getInstance();
    return OpeningHours(
      enabled: prefs.getBool(_enabled) ?? false,
      openHour: prefs.getInt(_open) ?? 8,
      closeHour: prefs.getInt(_close) ?? 20,
    );
  }

  static Future<void> save(OpeningHours hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabled, hours.enabled);
    await prefs.setInt(_open, hours.openHour);
    await prefs.setInt(_close, hours.closeHour);
  }
}
