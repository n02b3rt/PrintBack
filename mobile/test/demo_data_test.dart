import 'package:flutter_test/flutter_test.dart';
import 'package:printback/services/demo_data.dart';

void main() {
  final today = DateTime(2026, 7, 16);

  test('generates one daily row per requested day', () {
    final rows = DemoData.generate(today: today, days: 30);
    final daily = rows.where((a) => a.hour == null).toList();
    expect(daily, hasLength(30));
    expect(daily.map((a) => a.date).toSet(), hasLength(30));
  });

  test('is deterministic - same day, same numbers', () {
    final a = DemoData.generate(today: today, days: 20);
    final b = DemoData.generate(today: today, days: 20);
    expect(a.map((r) => '${r.date}/${r.hour}/${r.unique}/${r.returning}'),
        b.map((r) => '${r.date}/${r.hour}/${r.unique}/${r.returning}'));
  });

  test('ends on today and runs backwards', () {
    final daily = DemoData.generate(today: today, days: 10)
        .where((a) => a.hour == null)
        .map((a) => a.date)
        .toList()
      ..sort();
    expect(daily.last, '2026-07-16');
    expect(daily.first, '2026-07-07');
  });

  test('returning never exceeds unique', () {
    for (final a in DemoData.generate(today: today, days: 60)) {
      expect(a.returning, lessThanOrEqualTo(a.unique));
      expect(a.returning, greaterThanOrEqualTo(0));
    }
  });

  test('every day has visitors, so a demo never looks broken', () {
    final daily = DemoData.generate(today: today, days: 60)
        .where((a) => a.hour == null);
    expect(daily.every((a) => a.unique > 0), isTrue);
  });

  // The demo must not look better than the product: the device only backfills
  // a week of hourly detail, so neither does this.
  //
  // At most seven days, not exactly seven: a day quiet enough that every
  // single hour lands under the k-anonymity threshold publishes no hourly
  // rows at all (the demo's Sunday does exactly this) - which is precisely
  // what the real device does, and worth keeping.
  test('hourly detail never reaches beyond the last week', () {
    final hourlyDates = DemoData.generate(today: today, days: 60)
        .where((a) => a.hour != null)
        .map((a) => a.date)
        .toSet();
    expect(hourlyDates, isNotEmpty);
    expect(hourlyDates.length, lessThanOrEqualTo(7));
    // today is 2026-07-16, so the window opens on the 10th.
    expect(hourlyDates.every((d) => d.compareTo('2026-07-10') >= 0), isTrue);
  });

  test('a day too quiet to clear the threshold publishes no hours at all', () {
    final rows = DemoData.generate(today: today, days: 60);
    // 2026-07-12 is a Sunday - the quietest day in the shape.
    expect(rows.any((a) => a.date == '2026-07-12' && a.hour == null), isTrue);
    expect(rows.any((a) => a.date == '2026-07-12' && a.hour != null), isFalse);
  });

  // Same reason: hours under the k-anonymity threshold are never published by
  // the firmware, so the demo's chart has the same honest gaps.
  test('never emits an hour below the k-anonymity threshold', () {
    final hourly =
        DemoData.generate(today: today, days: 60).where((a) => a.hour != null);
    expect(hourly.every((a) => a.unique >= 5), isTrue);
  });

  test('busy Saturdays, quiet Sundays', () {
    final daily = {
      for (final a
          in DemoData.generate(today: today, days: 28).where((a) => a.hour == null))
        a.date: a.unique
    };
    // 2026-07-11 is a Saturday, 2026-07-12 a Sunday.
    expect(daily['2026-07-11']!, greaterThan(daily['2026-07-12']!));
  });

  test('demo id is recognisable and not a bluetooth address', () {
    expect(DemoData.isDemo(DemoData.deviceId), isTrue);
    expect(DemoData.isDemo('AA:BB:CC:DD:EE:FF'), isFalse);
    expect(DemoData.isDemo(null), isFalse);
    expect(DemoData.deviceId, isNot(contains(':')));
  });
}
