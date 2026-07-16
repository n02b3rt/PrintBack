import 'dart:collection';

import 'package:flutter/foundation.dart';

/// In-memory ring buffer of recent app log lines - the raw material a
/// shake-triggered bug report attaches (`services/bug_report.dart`).
///
/// Privacy, by construction rather than by promise:
/// - Never written to disk and never transmitted on its own. It lives only
///   in RAM, is capped at [maxLines], and dies with the process.
/// - It cannot contain a store visitor's data: the phone never receives a
///   per-client identifier at all (docs/DECISIONS.md D3), only aggregate
///   counts. The only remotely identifying string that realistically shows
///   up here is the operator's own device's Bluetooth address, which
///   [scrub] masks anyway.
/// - Nothing leaves the buffer without the operator explicitly tapping
///   "send" on a sheet that previews the exact text first.
class LogBuffer {
  LogBuffer._();
  static final LogBuffer instance = LogBuffer._();

  static const int maxLines = 300;

  final Queue<String> _lines = Queue<String>();
  bool _installed = false;

  List<String> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;

  /// Masks the middle of anything shaped like a MAC/Bluetooth address, so a
  /// report can't carry a full hardware address even by accident. Keeps the
  /// first and last octet, which is enough to tell two devices apart while
  /// debugging.
  static String scrub(String input) {
    return input.replaceAllMapped(
      RegExp(r'\b([0-9A-Fa-f]{2}):(?:[0-9A-Fa-f]{2}:){4}([0-9A-Fa-f]{2})\b'),
      (m) => '${m[1]}:**:**:**:**:${m[2]}',
    );
  }

  void add(String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    for (final raw in message.split('\n')) {
      if (raw.trim().isEmpty) continue;
      _lines.addLast('$ts  ${scrub(raw)}');
      while (_lines.length > maxLines) {
        _lines.removeFirst();
      }
    }
  }

  void clear() => _lines.clear();

  /// Routes `debugPrint`, framework errors and uncaught async errors into the
  /// buffer, without swallowing any of them - each is still reported the way
  /// it was before. Idempotent: calling it twice won't double-wrap.
  void install() {
    if (_installed) return;
    _installed = true;

    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      original(message, wrapWidth: wrapWidth);
    };

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      add('FLUTTER ERROR: ${details.exceptionAsString()}');
      previousOnError?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      add('UNCAUGHT: $error');
      return false; // still let the platform report it
    };
  }
}
