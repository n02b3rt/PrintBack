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

  group('streak', () {
    test('fires once three or more days in a row beat the average', () {
      // Three low days pull the average down; the last three all clear it.
      final rows = [
        day('2026-07-06', 2),
        day('2026-07-07', 2),
        day('2026-07-08', 2),
        day('2026-07-09', 20),
        day('2026-07-10', 20),
        day('2026-07-11', 20),
      ];
      final streak = buildInsights(rows, limit: 5)
          .firstWhere((i) => i.kind == InsightKind.streak);
      expect(streak.count, 3);
    });

    test('does not fire on a run shorter than three', () {
      final rows = [
        day('2026-07-06', 2),
        day('2026-07-07', 2),
        day('2026-07-08', 2),
        day('2026-07-09', 2),
        day('2026-07-10', 20),
        day('2026-07-11', 20),
      ];
      expect(buildInsights(rows, limit: 5).any((i) => i.kind == InsightKind.streak),
          isFalse);
    });
  });

  group('percentile', () {
    test('fires when the latest beats most of the same weekdays', () {
      // Five previous Mondays, latest Monday beats four of them.
      final rows = [
        day('2026-06-08', 5),
        day('2026-06-15', 6),
        day('2026-06-22', 7),
        day('2026-06-29', 8),
        day('2026-07-06', 50),
        day('2026-07-13', 40), // Mon, latest: beats 4 of 5
      ];
      final p = buildInsights(rows, limit: 5)
          .firstWhere((i) => i.kind == InsightKind.percentile);
      expect(p.count, 4);
      expect(p.total, 5);
    });

    test('stays quiet with too few same-weekday samples to rank against', () {
      final rows = [
        day('2026-06-29', 5),
        day('2026-07-06', 6),
        day('2026-07-13', 40), // only 2 previous Mondays
      ];
      expect(
          buildInsights(rows, limit: 5)
              .any((i) => i.kind == InsightKind.percentile),
          isFalse);
    });
  });

  group('rotation', () {
    // A day that fires record + streak + up + percentile: more than fits.
    List<Aggregate> busy() => [
          day('2026-06-08', 2),
          day('2026-06-15', 2),
          day('2026-06-22', 2),
          day('2026-06-29', 2),
          day('2026-07-04', 30),
          day('2026-07-05', 30),
          day('2026-07-06', 30),
          day('2026-07-13', 60), // Mon, latest: record, streak, up, percentile
        ];

    test('the headline is the same whatever the seed', () {
      final a = buildInsights(busy(), rotationSeed: 0).first;
      final b = buildInsights(busy(), rotationSeed: 5).first;
      expect(a, b);
      expect(a.kind, InsightKind.record);
    });

    test('the secondary slot changes with the seed', () {
      final picks = {
        for (var seed = 0; seed < 4; seed++)
          buildInsights(busy(), rotationSeed: seed)[1].kind
      };
      expect(picks.length, greaterThan(1),
          reason: 'rotation should surface different secondary insights');
    });

    test('the same seed always gives the same pick', () {
      expect(buildInsights(busy(), rotationSeed: 3),
          buildInsights(busy(), rotationSeed: 3));
    });

    test('never returns more than the limit', () {
      expect(buildInsights(busy(), limit: 2, rotationSeed: 7).length, 2);
      expect(buildInsights(busy(), limit: 1, rotationSeed: 7).length, 1);
    });
  });
}
