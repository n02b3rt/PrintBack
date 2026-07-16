import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../logic/stats_math.dart';
import '../services/excel_export.dart';
import '../storage/local_db.dart';
import 'report_preview.dart';

/// The periods a report or an export can cover.
///
/// Both actions used to assume one: the panel's "Raport" button silently
/// meant today, and "Eksport" dodged the question by dumping the operator on
/// the statistics screen and letting them find the export button themselves.
/// Neither is a choice the app gets to make - so both now ask.
enum QuickPeriod { today, week, month }

DateTimeRange quickRange(QuickPeriod p) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return switch (p) {
    QuickPeriod.today => DateTimeRange(start: today, end: today),
    QuickPeriod.week => DateTimeRange(
        start: today.subtract(const Duration(days: 6)), end: today),
    QuickPeriod.month => DateTimeRange(
        start: today.subtract(const Duration(days: 29)), end: today),
  };
}

String quickPeriodLabel(AppLocalizations l10n, QuickPeriod p) => switch (p) {
      QuickPeriod.today => l10n.periodToday,
      QuickPeriod.week => l10n.periodWeek,
      QuickPeriod.month => l10n.periodMonth,
    };

/// Asks which period, returning null if the operator backs out.
Future<QuickPeriod?> pickQuickPeriod(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<QuickPeriod>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.pickPeriodTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
          ),
          for (final p in QuickPeriod.values)
            ListTile(
              title: Text(quickPeriodLabel(l10n, p)),
              onTap: () => Navigator.of(ctx).pop(p),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _fmtHuman(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _rangeText(DateTimeRange r) => r.start == r.end
    ? _fmtHuman(r.start)
    : '${_fmtHuman(r.start)} - ${_fmtHuman(r.end)}';

/// Opens the shareable report card for [range]. Reads the cache, so it works
/// offline like everything else on these screens.
Future<void> openReportForRange(
  BuildContext context, {
  required String deviceId,
  required DateTimeRange range,
  required String periodLabel,
}) async {
  final daily =
      await LocalDb().dailyInRange(deviceId, _fmt(range.start), _fmt(range.end));
  final unique = sumUnique(daily);
  final returning = sumReturning(daily);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ReportPreview(
      periodLabel: periodLabel,
      dateRange: _rangeText(range),
      unique: unique,
      newVisitors: (unique - returning).clamp(0, unique),
      returning: returning,
    ),
  ));
}

/// Builds the .xlsx for [range] and hands it to the share sheet. Aggregates
/// only - the same rows the charts draw.
Future<void> exportRangeToExcel(
  BuildContext context, {
  required String deviceId,
  required DateTimeRange range,
  required List<String> weekdaysFull,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final ble = context.read<BleService>();

  final from = _fmt(range.start);
  final to = _fmt(range.end);
  final db = LocalDb();
  final daily = await db.dailyInRange(deviceId, from, to);
  // A day of padding each side, then filtered by local date: hourly rows are
  // dated UTC on the wire and an hour near local midnight lands on the other
  // side (docs/LEARNINGS.md 2026-07-11).
  final hourlyPadded = await db.hourlyInRange(
    deviceId,
    _fmt(range.start.subtract(const Duration(days: 1))),
    _fmt(range.end.add(const Duration(days: 1))),
  );
  final hourly = hourlyPadded
      .where((a) => a.localDate.compareTo(from) >= 0 && a.localDate.compareTo(to) <= 0)
      .toList();

  String appVersion = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {}

  // Nice to have in the metadata, never worth hanging the export for.
  String? fw;
  if (ble.isConnectedReady) {
    try {
      fw = (await ble.readStatus().timeout(const Duration(seconds: 3)))?.fw;
    } catch (_) {}
  }

  final bytes = buildWorkbook(
    daily: daily,
    hourly: hourly,
    labels: ExcelLabels(
      sheetDays: l10n.excelSheetDays,
      sheetHours: l10n.excelSheetHours,
      sheetMeta: l10n.excelSheetMeta,
      colDate: l10n.excelColDate,
      colWeekday: l10n.excelColWeekday,
      colHour: l10n.excelColHour,
      colUnique: l10n.excelColUnique,
      colReturning: l10n.excelColReturning,
      colNew: l10n.excelColNew,
      colReturningPct: l10n.excelColReturningPct,
      colKanon: l10n.excelColKanon,
      metaKey: l10n.excelMetaKey,
      metaValue: l10n.excelMetaValue,
      metaGenerated: l10n.excelMetaGenerated,
      metaRange: l10n.excelMetaRange,
      metaApp: l10n.excelMetaApp,
      metaFirmware: l10n.excelMetaFirmware,
      metaNote: l10n.excelMetaNote,
      noteText: l10n.excelNote,
      yes: l10n.excelYes,
      no: l10n.excelNo,
      weekdays: weekdaysFull,
    ),
    rangeText: _rangeText(range),
    generatedAt: _fmtHuman(DateTime.now()),
    appVersion: appVersion,
    firmwareVersion: fw,
  );
  if (bytes == null) return;

  // The printback_export_ prefix is what shareWorkbook sweeps on the next
  // run - keep it.
  await shareWorkbook(bytes, 'printback_export_${from}_$to.xlsx',
      text: l10n.exportShareText);
}
