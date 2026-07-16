import 'package:flutter_test/flutter_test.dart';
import 'package:printback/logic/narrative.dart';
import 'package:printback/logic/stats_math.dart';
import 'package:printback/models/aggregate.dart';

Aggregate day(String date, int unique, {int returning = 0}) => Aggregate(
    date: date, hour: null, unique: unique, returning: returning, kanon: false);

void main() {
  test('nothing to say about an empty or visitor-less period', () {
    expect(buildPeriodNarrative([], []), isNull);
    expect(buildPeriodNarrative([day('2026-07-13', 0)], []), isNull);
  });

  test('totals, best day and returning share of a period', () {
    final week = [
      day('2026-07-13', 10, returning: 2),
      day('2026-07-14', 30, returning: 10),
      day('2026-07-15', 20, returning: 8),
    ];
    final n = buildPeriodNarrative(week, [])!;
    expect(n.total, 60);
    expect(n.bestDayCount, 30);
    expect(n.bestDayWeekday, weekdayIndex('2026-07-14'));
    expect(n.returningPct, 33); // 20/60
  });

  test('no comparison without a previous period', () {
    final n = buildPeriodNarrative([day('2026-07-13', 10)], [])!;
    expect(n.deltaPercent, isNull);
    expect(n.returningDeltaPoints, isNull);
  });

  test('no comparison when the previous period had no visitors', () {
    final n = buildPeriodNarrative(
        [day('2026-07-13', 10)], [day('2026-07-06', 0)])!;
    expect(n.deltaPercent, isNull);
  });

  test('compares the total against the previous period', () {
    final n = buildPeriodNarrative(
      [day('2026-07-13', 60)],
      [day('2026-07-06', 50)],
    )!;
    expect(n.deltaPercent, 20);
  });

  test('returning share moves in percentage points, not percent of percent',
      () {
    // 50% returning now vs 25% before: +25 points, NOT +100%.
    final n = buildPeriodNarrative(
      [day('2026-07-13', 100, returning: 50)],
      [day('2026-07-06', 100, returning: 25)],
    )!;
    expect(n.returningPct, 50);
    expect(n.returningDeltaPoints, 25);
  });

  test('a falling returning share reads negative', () {
    final n = buildPeriodNarrative(
      [day('2026-07-13', 100, returning: 20)],
      [day('2026-07-06', 100, returning: 40)],
    )!;
    expect(n.returningDeltaPoints, -20);
  });
}
