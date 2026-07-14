import 'package:shared_preferences/shared_preferences.dart';

/// One-time onboarding flags kept in shared_preferences. Thin wrapper so
/// the flag keys live in one place and screens don't sprinkle raw string
/// keys around. All default to false (not-yet-seen) on a fresh install.
class OnboardingFlags {
  static const _onboardingDone = 'onboarding_done';
  static const _coachMarksDone = 'coach_marks_done';
  static const _tipKanon = 'tip_kanon_seen';
  static const _tipReturningRate = 'tip_returning_rate_seen';

  static Future<bool> _get(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? false;
  }

  static Future<void> _set(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// True once the user has been through (or skipped) the welcome carousel
  /// and pairing wizard - gates whether the app opens onboarding or goes
  /// straight to its normal connect flow.
  static Future<bool> onboardingDone() => _get(_onboardingDone);
  static Future<void> setOnboardingDone() => _set(_onboardingDone, true);

  /// True once the first-dashboard coach marks have been shown or skipped.
  static Future<bool> coachMarksDone() => _get(_coachMarksDone);
  static Future<void> setCoachMarksDone(bool done) =>
      _set(_coachMarksDone, done);

  /// One-shot educational tooltips (docs/../report 3.6).
  static Future<bool> kanonTipSeen() => _get(_tipKanon);
  static Future<void> setKanonTipSeen() => _set(_tipKanon, true);

  static Future<bool> returningRateTipSeen() => _get(_tipReturningRate);
  static Future<void> setReturningRateTipSeen() =>
      _set(_tipReturningRate, true);
}
