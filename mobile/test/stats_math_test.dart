import 'package:flutter_test/flutter_test.dart';
import 'package:printback/logic/stats_math.dart';
import 'package:printback/models/aggregate.dart';

Aggregate daily(String date, int unique, {int returning = 0}) =>
    Aggregate(date: date, hour: null, unique: unique, returning: returning, kanon: false);

Aggregate hourly(String date, int hour, int unique) =>
    Aggregate(date: date, hour: hour, unique: unique, returning: 0, kanon: false);

void main() {
  group('sums', () {
    test('empty is zero', () {
      expect(sumUnique([]), 0);
      expect(sumReturning([]), 0);
    });
    test('adds up', () {
      final rows = [daily('2026-07-10', 5, returning: 2), daily('2026-07-11', 3, returning: 1)];
      expect(sumUnique(rows), 8);
      expect(sumReturning(rows), 3);
    });
  });

  group('deltaPercent', () {
    test('null when no previous baseline', () {
      expect(deltaPercent(10, 0), isNull);
    });
    test('positive and negative change', () {
      expect(deltaPercent(150, 100), 50);
      expect(deltaPercent(80, 100), -20);
    });
  });

  group('returningRate', () {
    test('zero visitors is 0, not a divide-by-zero', () {
      expect(returningRate(0, 0), 0);
    });
    test('rounds to a percent', () {
      expect(returningRate(200, 50), 25);
      expect(returningRate(3, 1), 33);
    });
  });

  group('averagePerDay', () {
    test('empty period is 0', () => expect(averagePerDay(0, 0), 0));
    test('single day equals the total', () => expect(averagePerDay(7, 1), 7));
    test('rounds the mean', () => expect(averagePerDay(10, 3), 3));
  });

  group('weekdayIndex', () {
    test('Monday is 0, Sunday is 6', () {
      expect(weekdayIndex('2026-07-13'), 0); // a Monday
      expect(weekdayIndex('2026-07-19'), 6); // the Sunday after
    });
  });

  group('weekdayAverages', () {
    test('empty gives all zeros', () {
      expect(weekdayAverages([]), List<double>.filled(7, 0.0));
    });
    test('averages per weekday, empty weekdays are 0', () {
      final rows = [
        daily('2026-07-13', 10), // Mon
        daily('2026-07-20', 20), // Mon
        daily('2026-07-14', 5), // Tue
      ];
      final avgs = weekdayAverages(rows);
      expect(avgs[0], 15.0); // Monday mean of 10 and 20
      expect(avgs[1], 5.0); // Tuesday
      expect(avgs[2], 0.0); // Wednesday, no data
    });
  });

  group('bestDay', () {
    test('null for empty', () => expect(bestDay([]), isNull));
    test('picks the max unique', () {
      final rows = [daily('2026-07-10', 3), daily('2026-07-11', 9), daily('2026-07-12', 4)];
      expect(bestDay(rows)!.date, '2026-07-11');
    });
    test('tie keeps the first max seen', () {
      final rows = [daily('2026-07-10', 9), daily('2026-07-11', 9)];
      expect(bestDay(rows)!.date, '2026-07-10');
    });
  });

  group('peakHour', () {
    test('null with no hourly data', () => expect(peakHour([]), isNull));
    test('returns the local hour of the highest-average bucket', () {
      // Compare against the input's own localHour so the assertion is
      // timezone-independent (localHour converts UTC->local).
      final rows = [hourly('2026-07-11', 8, 2), hourly('2026-07-11', 14, 9)];
      expect(peakHour(rows), rows[1].localHour);
    });
  });

  group('classifyTrend', () {
    test('extreme short-circuits', () {
      final r = classifyTrend(1, 100, isExtreme: true);
      expect(r.cls, TrendClass.extreme);
    });
    test('above / below / around thresholds', () {
      expect(classifyTrend(130, 100, isExtreme: false).cls, TrendClass.above);
      expect(classifyTrend(70, 100, isExtreme: false).cls, TrendClass.below);
      expect(classifyTrend(100, 100, isExtreme: false).cls, TrendClass.around);
    });
    test('around when there is no average to compare against', () {
      expect(classifyTrend(5, 0, isExtreme: false).cls, TrendClass.around);
    });
    test('percent magnitude', () {
      expect(classifyTrend(150, 100, isExtreme: false).percent, 50);
      expect(classifyTrend(60, 100, isExtreme: false).percent, 40);
    });
  });
}
