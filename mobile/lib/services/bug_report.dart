import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../ble/ble_service.dart';
import '../models/device_status.dart';
import '../storage/local_db.dart';
import 'log_buffer.dart';

/// One assembled diagnostic report, ready to be previewed and (only then)
/// submitted. Everything in here is the operator's own technical data about
/// their own device - by architecture no store-visitor data exists on the
/// phone to leak (docs/DECISIONS.md D3: only aggregate counts ever arrive).
class BugReport {
  final DateTime timestamp;
  final String description;
  final String appVersion;
  final String platform;
  final Map<String, String> state;

  /// Empty when the operator switched "include technical logs" off.
  final List<String> logs;

  const BugReport({
    required this.timestamp,
    required this.description,
    required this.appVersion,
    required this.platform,
    required this.state,
    required this.logs,
  });

  /// The exact text that gets submitted - the sheet previews this verbatim,
  /// so what the operator sees is what is sent.
  String toText() {
    final b = StringBuffer()
      ..writeln('PrintBack bug report')
      ..writeln('when: ${timestamp.toIso8601String()}')
      ..writeln('app: $appVersion')
      ..writeln('platform: $platform')
      ..writeln();

    b.writeln('-- what happened --');
    b.writeln(description.trim().isEmpty ? '(not described)' : description.trim());
    b.writeln();

    b.writeln('-- state --');
    state.forEach((k, v) => b.writeln('$k: $v'));

    if (logs.isNotEmpty) {
      b
        ..writeln()
        ..writeln('-- recent logs (${logs.length} lines) --');
      for (final l in logs) {
        b.writeln(l);
      }
    }
    return b.toString();
  }
}

/// Where a submitted report goes. Deliberately an interface: today the app
/// has no backend and deliberately makes no network calls of its own, so the
/// default hands the text to the OS share sheet and lets the operator pick
/// the channel. When the Play Console / support panel lands, plugging it in
/// is one new implementation of this - no changes to the gesture, the
/// collection, or the consent sheet.
abstract class BugReportSink {
  Future<void> submit(BugReport report);
}

/// Default sink: the OS share sheet. Chosen over a hardcoded endpoint or
/// e-mail address on purpose - nothing is uploaded anywhere by us, the
/// operator decides the destination, so no third-party processor and no
/// backend privacy policy are involved yet.
class ShareBugReportSink implements BugReportSink {
  const ShareBugReportSink();

  @override
  Future<void> submit(BugReport report) async {
    await Share.share(report.toText(), subject: 'PrintBack bug report');
  }
}

/// Gathers the diagnostic snapshot. [includeLogs] is the operator's choice
/// from the sheet, not a default we make for them.
Future<BugReport> buildBugReport({
  required BleService ble,
  required String description,
  required bool includeLogs,
}) async {
  String appVersion = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {}

  String platform = 'unknown';
  if (!kIsWeb) {
    try {
      platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {}
  }

  final state = <String, String>{
    'connection': ble.connectionState.name,
    'ready': ble.isConnectedReady.toString(),
    'reconnecting': ble.isReconnecting.toString(),
    'syncing': ble.isSyncing.toString(),
    'last_sync': ble.lastSyncCompleted?.toIso8601String() ?? 'never',
    'paired_device': ble.activeDeviceId == null ? 'none' : 'yes',
  };

  final deviceId = ble.activeDeviceId;
  if (deviceId != null) {
    try {
      final daily = await LocalDb().recentDaily(deviceId);
      state['cached_days'] = daily.length.toString();
      if (daily.isNotEmpty) {
        final dates = daily.map((a) => a.date).toList()..sort();
        state['cached_range'] = '${dates.first} .. ${dates.last}';
      }
    } catch (e) {
      state['cached_days'] = 'error: $e';
    }
  }

  // Best-effort and time-boxed: if the bug being reported IS the BLE link,
  // this read is exactly what will hang, and a report that never assembles
  // is worse than one missing a field.
  if (ble.isConnectedReady) {
    try {
      final DeviceStatus? s =
          await ble.readStatus().timeout(const Duration(seconds: 3));
      if (s != null) {
        state['device_fw'] = s.fw;
        state['device_sd_ok'] = s.sdOk.toString();
        state['device_sd_free_mb'] = s.sdFreeMb.toString();
        state['device_uptime_s'] = s.uptimeS.toString();
        state['device_heap'] = s.heap.toString();
        state['device_reset'] = s.reset;
        if (s.whitelistCount != null) {
          state['device_whitelist'] = s.whitelistCount.toString();
        }
      }
    } catch (e) {
      state['device_status'] = 'unavailable ($e)';
    }
  }

  return BugReport(
    timestamp: DateTime.now(),
    description: description,
    appVersion: appVersion,
    platform: platform,
    state: state,
    logs: includeLogs ? LogBuffer.instance.lines : const [],
  );
}
