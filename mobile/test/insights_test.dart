import 'package:flutter_test/flutter_test.dart';
import 'package:printback/logic/insights.dart';
import 'package:printback/models/aggregate.dart';

Aggregate day(String date, int unique) =>
    Aggregate(date: date, hour: null, unique: unique, returning: 0, kanon: false);

void main() {
  test('empty or zero-latest yields nothing', () {
    expect(buildInsights([]), isEmpty);
    expect(buildInsights([day('2026-07-13', 0)]), isEmpty);
  });

  test('record when the latest day is the period max', () {
    // 3 Mondays + others, latest is the highest overall.
    final rows = [
      day('2026-07-06', 10), // Mon
      day('2026-07-07', 8),
      day('2026-07-13', 20), // Mon, latest, highest
    ];
    expect(buildInsights(rows).first.kind, InsightKind.record);
  });

  test('up when latest is >=15% over the same-weekday average', () {
    final rows = [
      day('2026-06-29', 100), // Mon
      day('2026-07-06', 100), // Mon
      day('2026-07-08', 300), // Wed (keeps latest from being the period max)
      day('2026-07-13', 130), // Mon, latest: +30% vs Monday avg of 100
    ];
    final ins = buildInsights(rows);
    final up = ins.firstWhere((i) => i.kind == InsightKind.up);
    expect(up.percent, 30);
  });

  test('down when latest is >=15% under the same-weekday average', () {
    final rows = [
      day('2026-06-29', 100), // Mon
      day('2026-07-06', 100), // Mon
      day('2026-07-08', 300), // Wed
      day('2026-07-13', 70), // Mon, latest: -30%
    ];
    final down = buildInsights(rows).firstWhere((i) => i.kind == InsightKind.down);
    expect(down.percent, 30);
  });

  test('quiet only as a fallback when nothing else fires', () {
    // Latest well below the overall average, not a same-weekday match set.
    final rows = [
      day('2026-07-07', 100), // Tue
      day('2026-07-08', 120), // Wed
      day('2026-07-09', 20), // Thu, latest: overall avg 80, 20 < 0.6*80=48
    ];
    expect(buildInsights(rows).single.kind, InsightKind.quiet);
  });

  test('at most `limit` insights', () {
    final rows = [
      day('2026-06-29', 50), // Mon
      day('2026-07-06', 50), // Mon
      day('2026-07-08', 10), // Wed
      day('2026-07-13', 200), // Mon, latest: record AND way up
    ];
    expect(buildInsights(rows, limit: 2).length, lessThanOrEqualTo(2));
  });
}
