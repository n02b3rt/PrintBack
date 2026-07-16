import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printback/models/aggregate.dart';
import 'package:printback/services/excel_export.dart';

const _labels = ExcelLabels(
  sheetDays: 'Dni',
  sheetHours: 'Godziny',
  sheetMeta: 'Metadane',
  colDate: 'Data',
  colWeekday: 'Dzien tygodnia',
  colHour: 'Godzina',
  colUnique: 'Odwiedzajacy',
  colReturning: 'Powracajacy',
  colNew: 'Nowi',
  colReturningPct: '% powracajacych',
  colKanon: 'Kanon',
  metaKey: 'Pole',
  metaValue: 'Wartosc',
  metaGenerated: 'Wygenerowano',
  metaRange: 'Zakres',
  metaApp: 'Aplikacja',
  metaFirmware: 'Firmware',
  metaNote: 'Uwaga',
  noteText: 'Szacunek trendu na podstawie sygnalow WiFi.',
  yes: 'tak',
  no: 'nie',
  weekdays: ['Pn', 'Wt', 'Sr', 'Cz', 'Pt', 'So', 'Nd'],
);

Aggregate day(String date, int unique, {int returning = 0, bool kanon = false}) =>
    Aggregate(
        date: date, hour: null, unique: unique, returning: returning, kanon: kanon);

Aggregate hour(String date, int h, int unique) =>
    Aggregate(date: date, hour: h, unique: unique, returning: 0, kanon: false);

/// Reads the workbook back the way Excel would, so the assertions are about
/// the real file rather than about our own in-memory objects.
Excel _roundTrip(List<int> bytes) => Excel.decodeBytes(bytes);

void main() {
  List<int> build({List<Aggregate>? daily, List<Aggregate>? hourly}) =>
      buildWorkbook(
        daily: daily ?? [day('2026-07-14', 10, returning: 4)],
        hourly: hourly ?? [hour('2026-07-14', 12, 5)],
        labels: _labels,
        rangeText: '01.07.2026 - 14.07.2026',
        generatedAt: '2026-07-16 18:00',
        appVersion: '1.0.0+1',
        firmwareVersion: '5563585',
      )!;

  test('produces a decodable workbook with the three named sheets', () {
    final x = _roundTrip(build());
    expect(x.tables.keys, containsAll(['Dni', 'Godziny', 'Metadane']));
  });

  test('drops the template default sheet', () {
    final x = _roundTrip(build());
    expect(x.tables.keys, hasLength(3));
  });

  test('writes a header row plus one row per day, computing new and pct', () {
    final x = _roundTrip(build(
        daily: [day('2026-07-14', 10, returning: 4, kanon: true)]));
    final rows = x.tables['Dni']!.rows;
    expect(rows.first.first?.value.toString(), 'Data');
    final r = rows[1];
    expect(r[0]?.value.toString(), '2026-07-14');
    expect(r[2]?.value, const IntCellValue(10)); // unique
    expect(r[3]?.value, const IntCellValue(4)); // returning
    expect(r[4]?.value, const IntCellValue(6)); // new = unique - returning
    expect(r[5]?.value, const IntCellValue(40)); // 4/10
    expect(r[6]?.value.toString(), 'tak'); // kanon flag localized
  });

  test('sorts days ascending regardless of input order', () {
    final x = _roundTrip(build(daily: [
      day('2026-07-15', 1),
      day('2026-07-13', 2),
      day('2026-07-14', 3),
    ]));
    final rows = x.tables['Dni']!.rows;
    expect(rows[1][0]?.value.toString(), '2026-07-13');
    expect(rows[2][0]?.value.toString(), '2026-07-14');
    expect(rows[3][0]?.value.toString(), '2026-07-15');
  });

  test('always carries the honest-precision note in the metadata', () {
    final x = _roundTrip(build());
    final flat = x.tables['Metadane']!.rows
        .expand((r) => r)
        .map((c) => c?.value.toString() ?? '')
        .join(' ');
    expect(flat, contains('Szacunek trendu'));
    expect(flat, contains('5563585')); // firmware version
    expect(flat, contains('1.0.0+1')); // app version
  });

  test('omits the firmware row when the device version is unknown', () {
    final bytes = buildWorkbook(
      daily: [day('2026-07-14', 10)],
      hourly: const [],
      labels: _labels,
      rangeText: 'x',
      generatedAt: 'y',
      appVersion: '1.0.0+1',
      firmwareVersion: null,
    )!;
    final flat = _roundTrip(bytes)
        .tables['Metadane']!
        .rows
        .expand((r) => r)
        .map((c) => c?.value.toString() ?? '')
        .join(' ');
    expect(flat, isNot(contains('Firmware')));
  });

  test('handles an empty period without blowing up', () {
    final bytes = buildWorkbook(
      daily: const [],
      hourly: const [],
      labels: _labels,
      rangeText: 'x',
      generatedAt: 'y',
      appVersion: '1.0.0+1',
    )!;
    final x = _roundTrip(bytes);
    expect(x.tables['Dni']!.rows, hasLength(1)); // header only
  });
}
