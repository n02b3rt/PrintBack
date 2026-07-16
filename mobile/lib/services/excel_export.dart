import 'dart:io';

import 'package:excel/excel.dart';
import 'package:share_plus/share_plus.dart';

import '../logic/stats_math.dart';
import '../models/aggregate.dart';

/// Localized text for the workbook. Passed in from the screen rather than
/// read here, keeping l10n out of the logic the same way the rest of
/// `lib/logic` and `lib/services` do it.
class ExcelLabels {
  final String sheetDays;
  final String sheetHours;
  final String sheetMeta;

  final String colDate;
  final String colWeekday;
  final String colHour;
  final String colUnique;
  final String colReturning;
  final String colNew;
  final String colReturningPct;
  final String colKanon;

  final String metaKey;
  final String metaValue;
  final String metaGenerated;
  final String metaRange;
  final String metaApp;
  final String metaFirmware;
  final String metaNote;

  /// The honest-precision disclaimer (docs/compliance/README.md). Not
  /// optional: a spreadsheet reads as gospel unless it says otherwise.
  final String noteText;

  final String yes;
  final String no;
  final List<String> weekdays;

  const ExcelLabels({
    required this.sheetDays,
    required this.sheetHours,
    required this.sheetMeta,
    required this.colDate,
    required this.colWeekday,
    required this.colHour,
    required this.colUnique,
    required this.colReturning,
    required this.colNew,
    required this.colReturningPct,
    required this.colKanon,
    required this.metaKey,
    required this.metaValue,
    required this.metaGenerated,
    required this.metaRange,
    required this.metaApp,
    required this.metaFirmware,
    required this.metaNote,
    required this.noteText,
    required this.yes,
    required this.no,
    required this.weekdays,
  });
}

/// Builds the .xlsx bytes for [daily]/[hourly].
///
/// Exports exactly the columns the phone's cache holds - date, hour and
/// counts - and nothing else. There is deliberately no path in here to the
/// device's raw SD records: those are pseudonymous, and the entire legal
/// position rests on that export not existing (docs/compliance/README.md,
/// "No raw L1 export"). Everything below is anonymous aggregate statistics,
/// which is why an exported file needs no retention rule at all.
List<int>? buildWorkbook({
  required List<Aggregate> daily,
  required List<Aggregate> hourly,
  required ExcelLabels labels,
  required String rangeText,
  required String generatedAt,
  required String appVersion,
  String? firmwareVersion,
}) {
  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();

  final days = excel[labels.sheetDays];
  days.appendRow([
    TextCellValue(labels.colDate),
    TextCellValue(labels.colWeekday),
    TextCellValue(labels.colUnique),
    TextCellValue(labels.colReturning),
    TextCellValue(labels.colNew),
    TextCellValue(labels.colReturningPct),
    TextCellValue(labels.colKanon),
  ]);
  final sortedDaily = [...daily]..sort((a, b) => a.date.compareTo(b.date));
  for (final a in sortedDaily) {
    days.appendRow([
      TextCellValue(a.date),
      TextCellValue(labels.weekdays[weekdayIndex(a.date)]),
      IntCellValue(a.unique),
      IntCellValue(a.returning),
      IntCellValue((a.unique - a.returning).clamp(0, a.unique)),
      IntCellValue(returningRate(a.unique, a.returning)),
      TextCellValue(a.kanon ? labels.yes : labels.no),
    ]);
  }

  final hours = excel[labels.sheetHours];
  hours.appendRow([
    TextCellValue(labels.colDate),
    TextCellValue(labels.colHour),
    TextCellValue(labels.colUnique),
    TextCellValue(labels.colReturning),
  ]);
  // Hourly rows are dated in UTC on the wire; export what the app shows,
  // i.e. the operator's local date/hour (docs/LEARNINGS.md 2026-07-11).
  final sortedHourly = [...hourly]..sort((a, b) {
      final d = a.localDate.compareTo(b.localDate);
      return d != 0 ? d : a.localHour.compareTo(b.localHour);
    });
  for (final a in sortedHourly) {
    hours.appendRow([
      TextCellValue(a.localDate),
      IntCellValue(a.localHour),
      IntCellValue(a.unique),
      IntCellValue(a.returning),
    ]);
  }

  final meta = excel[labels.sheetMeta];
  meta.appendRow(
      [TextCellValue(labels.metaKey), TextCellValue(labels.metaValue)]);
  meta.appendRow(
      [TextCellValue(labels.metaGenerated), TextCellValue(generatedAt)]);
  meta.appendRow([TextCellValue(labels.metaRange), TextCellValue(rangeText)]);
  meta.appendRow([TextCellValue(labels.metaApp), TextCellValue(appVersion)]);
  if (firmwareVersion != null) {
    meta.appendRow(
        [TextCellValue(labels.metaFirmware), TextCellValue(firmwareVersion)]);
  }
  meta.appendRow(
      [TextCellValue(labels.metaNote), TextCellValue(labels.noteText)]);

  if (defaultSheet != null &&
      defaultSheet != labels.sheetDays &&
      defaultSheet != labels.sheetHours &&
      defaultSheet != labels.sheetMeta) {
    excel.delete(defaultSheet);
  }
  return excel.encode();
}

/// Writes the workbook to the app's cache directory and hands it to the OS
/// share sheet.
///
/// Old exports are swept on the way in rather than the new one being deleted
/// on the way out: `shareXFiles` returns when the sheet closes, but the
/// receiving app may still be reading the file through its content URI, and
/// deleting it there produces an empty attachment. The cache directory is
/// app-private and OS-reclaimable, so nothing lingers where the operator
/// would trip over it, and the app keeps no copy it would ever read back.
Future<void> shareWorkbook(List<int> bytes, String filename,
    {String? text}) async {
  final dir = Directory.systemTemp;
  try {
    for (final f in dir.listSync()) {
      if (f is File &&
          f.uri.pathSegments.last.startsWith('printback_export_')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  } catch (_) {}

  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles(
    [
      XFile(file.path,
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
    ],
    text: text,
  );
}
