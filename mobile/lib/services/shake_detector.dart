import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Detects "shake the phone hard, three times" and fires [onShake] once.
///
/// Reads `userAccelerometerEventStream` (device acceleration with gravity
/// already removed, so orientation doesn't matter). A single jolt past
/// [threshold] counts as one shake; [minGap] debounces the many samples a
/// single physical jolt produces. [requiredShakes] jolts must land within
/// [window] of the first one, otherwise the count restarts - so slow
/// incidental knocks never accumulate into a trigger.
class ShakeDetector {
  ShakeDetector({
    required this.onShake,
    this.requiredShakes = 3,
    this.threshold = 16.0,
    this.window = const Duration(milliseconds: 2500),
    this.minGap = const Duration(milliseconds: 220),
    this.cooldown = const Duration(seconds: 3),
  });

  final void Function() onShake;
  final int requiredShakes;

  /// Magnitude in m/s^2 that counts as a deliberate jolt. Well above normal
  /// handling/walking (a few m/s^2), so "hard shake" is the only thing that
  /// reaches it.
  final double threshold;
  final Duration window;
  final Duration minGap;

  /// Ignore everything for a moment after firing, so one long shake doesn't
  /// re-trigger the sheet the instant it closes.
  final Duration cooldown;

  StreamSubscription<UserAccelerometerEvent>? _sub;
  int _count = 0;
  DateTime? _firstShake;
  DateTime? _lastShake;
  DateTime? _firedAt;

  bool get isRunning => _sub != null;

  void start() {
    if (_sub != null) return;
    _sub = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onEvent, onError: (_) {/* no accelerometer: feature is just off */});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _reset();
  }

  void _reset() {
    _count = 0;
    _firstShake = null;
    _lastShake = null;
  }

  void _onEvent(UserAccelerometerEvent e) {
    final now = DateTime.now();
    if (_firedAt != null && now.difference(_firedAt!) < cooldown) return;

    final magnitude = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (magnitude < threshold) return;

    // One physical jolt spans many samples above the threshold; only the
    // first of them counts.
    if (_lastShake != null && now.difference(_lastShake!) < minGap) return;

    // Too slow to be part of the same gesture: this jolt starts a new run.
    if (_firstShake == null || now.difference(_firstShake!) > window) {
      _firstShake = now;
      _count = 0;
    }

    _lastShake = now;
    _count++;

    if (_count >= requiredShakes) {
      _firedAt = now;
      _reset();
      onShake();
    }
  }
}
