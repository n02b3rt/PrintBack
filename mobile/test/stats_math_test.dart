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

  group('sync end marker', () {
    test('a 1970-01-01 row is the sentinel', () {
      expect(daily('1970-01-01', 0).isSyncEndMarker, isTrue);
    });
    test('a real aggregate is not the sentinel', () {
      expect(daily('2026-07-12', 0).isSyncEndMarker, isFalse);
      expect(hourly('2026-07-12', 0, 0).isSyncEndMarker, isFalse);
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

  group('onlyWeekday', () {
    // 2026-07-06 is a Monday, so 07-07 / 07-14 / 07-21 are Tuesdays.
    final rows = [
      daily('2026-07-21', 30),
      daily('2026-07-06', 10),
      daily('2026-07-07', 10),
      daily('2026-07-14', 20),
    ];

    test('picks out one weekday and orders it oldest first', () {
      final tuesdays = onlyWeekday(rows, weekdayIndex('2026-07-07'));
      expect(tuesdays.map((a) => a.date), ['2026-07-07', '2026-07-14', '2026-07-21']);
    });

    test('leaves the other weekdays alone', () {
      final mondays = onlyWeekday(rows, weekdayIndex('2026-07-06'));
      expect(mondays.map((a) => a.date), ['2026-07-06']);
    });

    test('a weekday with no rows is empty, not an error', () {
      expect(onlyWeekday(rows, weekdayIndex('2026-07-12')), isEmpty); // Sunday
    });
  });

  group('withoutInstallDay', () {
    test('drops the install day wherever it sits in the list', () {
      final rows = [
        daily('2026-07-10', 3), // install day - half a day of traffic
        daily('2026-07-11', 100),
        daily('2026-07-12', 110),
      ];
      final kept = withoutInstallDay(rows, '2026-07-10');
      expect(kept.map((a) => a.date), ['2026-07-11', '2026-07-12']);
    });

    test('keeps everything when the install day is outside the period', () {
      // "Last 7 days" of a device installed a month ago: its first row is an
      // ordinary complete day and must not be thrown away.
      final rows = [daily('2026-07-11', 100), daily('2026-07-12', 110)];
      expect(withoutInstallDay(rows, '2026-06-01'), rows);
    });

    test('does nothing without an install date', () {
      final rows = [daily('2026-07-11', 100)];
      expect(withoutInstallDay(rows, null), rows);
    });

    test('never strips the only row, so day one still shows something', () {
      final rows = [daily('2026-07-10', 3)];
      expect(withoutInstallDay(rows, '2026-07-10'), rows);
    });

    test('an empty period stays empty', () {
      expect(withoutInstallDay([], '2026-07-10'), isEmpty);
    });

    test('the average stops being dragged under by the half day', () {
      final rows = [
        daily('2026-07-10', 4), // switched on late afternoon
        daily('2026-07-11', 100),
        daily('2026-07-12', 100),
      ];
      final before = averagePerDay(sumUnique(rows), rows.length);
      final kept = withoutInstallDay(rows, '2026-07-10');
      final after = averagePerDay(sumUnique(kept), kept.length);
      expect(before, 68); // 204/3 - a number describing no real day
      expect(after, 100);
    });
  });

  group('movingAverage', () {
    test('is null until a full window is available', () {
      final avg = movingAverage([1, 2, 3, 4], 3);
      expect(avg[0], isNull);
      expect(avg[1], isNull);
      expect(avg[2], closeTo(2, 0.001)); // (1+2+3)/3
      expect(avg[3], closeTo(3, 0.001)); // (2+3+4)/3
    });

    test('trails, so it never uses points from the future', () {
      final avg = movingAverage([10, 10, 10, 100], 3);
      expect(avg[2], closeTo(10, 0.001)); // the spike hasn't happened yet
      expect(avg[3], closeTo(40, 0.001));
    });

    test('a window of one is the series itself', () {
      expect(movingAverage([5, 7], 1), [5.0, 7.0]);
    });

    test('a window longer than the series is all null', () {
      expect(movingAverage([1, 2], 5), [null, null]);
    });

    test('handles empty input and a nonsense window', () {
      expect(movingAverage([], 3), isEmpty);
      expect(movingAverage([1, 2], 0), [null, null]);
    });
  });

  // These read the cut hour back off the data (`rows.first.localHour`) and
  // the weekday off the date, rather than hardcoding either: localHour is a
  // UTC->local conversion, so a hardcoded number would pass on this machine
  // (UTC+2) and fail in CI (UTC). Midday UTC hours keep every row on one
  // local calendar date for any realistic offset.
  group('typicalDayFraction', () {
    List<Aggregate> twoDaysHalfByNoon() => [
          hourly('2026-07-13', 10, 25),
          hourly('2026-07-13', 14, 25),
          hourly('2026-07-14', 10, 25),
          hourly('2026-07-14', 14, 25),
        ];

    test('null with fewer than minDays of hourly history', () {
      expect(typicalDayFraction([hourly('2026-07-14', 12, 10)], 23), isNull);
    });

    test('averages each day share of its own total up to the hour', () {
      final rows = [
        hourly('2026-07-13', 10, 10),
        hourly('2026-07-13', 14, 30),
        hourly('2026-07-14', 10, 10),
        hourly('2026-07-14', 14, 30),
      ];
      expect(typicalDayFraction(rows, rows.first.localHour),
          closeTo(0.25, 0.001));
    });

    test('is the whole day once the last hour is included', () {
      expect(typicalDayFraction(twoDaysHalfByNoon(), 23), closeTo(1.0, 0.001));
    });

    // The point of normalising within the hourly rows: these two days only
    // ever published a couple of hours (the rest fell under the k-anonymity
    // gate and never left the device), so their hourly totals are far below
    // the real day. The shape - half by the cut - must survive that.
    test('normalises within the hourly rows, so k-anonymity gaps do not skew it',
        () {
      final rows = [
        hourly('2026-07-13', 10, 5),
        hourly('2026-07-13', 14, 5),
        hourly('2026-07-14', 10, 5),
        hourly('2026-07-14', 14, 5),
      ];
      expect(
          typicalDayFraction(rows, rows.first.localHour), closeTo(0.5, 0.001));
    });
  });

  group('computeDayPace', () {
    // Shape: half the day's visitors have arrived by the cut hour.
    List<Aggregate> halfByCut() => [
          hourly('2026-07-13', 10, 25),
          hourly('2026-07-13', 14, 25),
          hourly('2026-07-14', 10, 25),
          hourly('2026-07-14', 14, 25),
        ];
    // Two same-weekday days (7 apart), 100 visitors each.
    const tueA = '2026-06-30';
    const tueB = '2026-07-07';

    DayPace? pace(int todaySoFar,
        {List<Aggregate>? past, List<Aggregate>? hours}) {
      final rows = hours ?? halfByCut();
      return computeDayPace(
        pastDaily: past ?? [daily(tueA, 100), daily(tueB, 100)],
        pastHourly: rows,
        todaySoFar: todaySoFar,
        todayWeekday: weekdayIndex(tueA),
        hour: halfByCut().first.localHour,
      );
    }

    test('null without enough same-weekday history', () {
      expect(pace(60, past: [daily(tueA, 100)]), isNull);
    });

    test('null without enough hourly shape to place the hour', () {
      expect(pace(60, hours: []), isNull);
    });

    test('scales a typical weekday total by the share of the day elapsed', () {
      final p = pace(50)!;
      expect(p.typicalFullDay, 100);
      expect(p.typicalByNow, 50); // 100 * 0.5
      expect(p.soFar, 50);
    });

    test('flags a busier-than-usual day', () {
      final p = pace(60)!;
      expect(p.deltaPercent, 20);
      expect(p.verdict, PaceVerdict.above);
    });

    test('flags a quieter-than-usual day', () {
      final p = pace(40)!;
      expect(p.deltaPercent, -20);
      expect(p.verdict, PaceVerdict.below);
    });

    test('calls a small difference typical rather than crying trend', () {
      expect(pace(53)!.verdict, PaceVerdict.typical); // +6%
      expect(pace(47)!.verdict, PaceVerdict.typical); // -6%
    });
  });
}
