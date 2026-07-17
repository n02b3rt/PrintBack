import 'package:flutter_test/flutter_test.dart';
import 'package:printback/logic/opening_hours.dart';
import 'package:printback/logic/stats_math.dart';
import 'package:printback/models/aggregate.dart';

void main() {
  group('DaySchedule', () {
    test('a normal daytime range is half-open', () {
      const d = DaySchedule(openHour: 8, closeHour: 20);
      expect(d.isOpen(7), isFalse);
      expect(d.isOpen(8), isTrue); // opening hour counts
      expect(d.isOpen(19), isTrue);
      expect(d.isOpen(20), isFalse); // closing hour does not
    });

    test('a range that wraps midnight still works', () {
      const d = DaySchedule(openHour: 22, closeHour: 4);
      expect(d.isOpen(23), isTrue);
      expect(d.isOpen(0), isTrue);
      expect(d.isOpen(3), isTrue);
      expect(d.isOpen(4), isFalse);
      expect(d.isOpen(12), isFalse);
    });

    test('a closed day is closed at every hour, whatever the range says', () {
      const d = DaySchedule(closed: true, openHour: 8, closeHour: 20);
      for (var h = 0; h < 24; h++) {
        expect(d.isOpen(h), isFalse, reason: 'hour $h');
      }
      expect(d.openHourCount, 0);
    });

    test('equal open and close means around the clock', () {
      const d = DaySchedule(openHour: 0, closeHour: 0);
      expect(d.isOpen(3), isTrue);
      expect(d.openHourCount, 24);
    });

    test('counts its open hours, including across midnight', () {
      expect(const DaySchedule(openHour: 8, closeHour: 20).openHourCount, 12);
      expect(const DaySchedule(openHour: 22, closeHour: 4).openHourCount, 6);
    });
  });

  group('OpeningHours', () {
    // The shape the request described: long weekdays, a short Saturday, a
    // closed Sunday, and one day off midweek.
    final realShop = OpeningHours(enabled: true, days: const [
      DaySchedule(openHour: 9, closeHour: 19), // Mon
      DaySchedule(openHour: 9, closeHour: 19), // Tue
      DaySchedule(closed: true), //                Wed - day off
      DaySchedule(openHour: 9, closeHour: 19), // Thu
      DaySchedule(openHour: 9, closeHour: 22), // Fri - late
      DaySchedule(openHour: 10, closeHour: 14), // Sat - short
      DaySchedule(closed: true), //                Sun
    ]);

    test('everything is open when the feature is off', () {
      for (var wd = 0; wd < 7; wd++) {
        for (var h = 0; h < 24; h++) {
          expect(OpeningHours.disabled.isOpenAt(wd, h), isTrue);
        }
      }
    });

    test('each weekday gets its own hours', () {
      expect(realShop.isOpenAt(0, 20), isFalse); // Mon closes at 19
      expect(realShop.isOpenAt(4, 20), isTrue); //  Fri is open until 22
      expect(realShop.isOpenAt(5, 13), isTrue); //  Sat open
      expect(realShop.isOpenAt(5, 15), isFalse); // Sat shuts at 14
    });

    test('a closed weekday is closed all day', () {
      for (var h = 0; h < 24; h++) {
        expect(realShop.isOpenAt(2, h), isFalse, reason: 'Wed $h'); // day off
        expect(realShop.isOpenAt(6, h), isFalse, reason: 'Sun $h');
      }
    });

    test('open-hour counts are per weekday, and zero on a closed day', () {
      expect(realShop.openHourCountOn(0), 10); // Mon 9-19
      expect(realShop.openHourCountOn(4), 13); // Fri 9-22
      expect(realShop.openHourCountOn(5), 4); //  Sat 10-14
      expect(realShop.openHourCountOn(6), 0); //  Sun closed
    });

    test('the count is a full day when the feature is off', () {
      expect(OpeningHours.disabled.openHourCountOn(6), 24);
    });

    test('copyWithDay touches only that day', () {
      final changed =
          realShop.copyWithDay(6, const DaySchedule(openHour: 11, closeHour: 15));
      expect(changed.isOpenAt(6, 12), isTrue); // Sunday now open
      expect(changed.days[0], realShop.days[0]); // Monday untouched
    });
  });

  group('splitByOpening', () {
    // localHour/localDate are UTC->local conversions, so the expectations are
    // read back off the data rather than hardcoded (CI runs in UTC).
    Aggregate h(String date, int hour) => Aggregate(
        date: date, hour: hour, unique: 5, returning: 0, kanon: false);

    test('judges each row against its own weekday schedule', () {
      // 2026-07-13 is a Monday, 2026-07-19 the Sunday after it.
      final monday = [for (var i = 0; i < 24; i++) h('2026-07-13', i)];
      final sunday = [for (var i = 0; i < 24; i++) h('2026-07-19', i)];
      final hours = OpeningHours(enabled: true, days: const [
        DaySchedule(openHour: 8, closeHour: 20), // Mon
        DaySchedule(), DaySchedule(), DaySchedule(), DaySchedule(),
        DaySchedule(),
        DaySchedule(closed: true), // Sun
      ]);

      final split = splitByOpening([...monday, ...sunday], hours);

      // Every Sunday row must be after-hours, whatever the clock says.
      expect(
        split.open.every((a) => weekdayIndex(a.localDate) != 6),
        isTrue,
        reason: 'a closed Sunday must never count as open',
      );
      expect(split.open.every((a) => hours.isOpenAt(weekdayIndex(a.localDate), a.localHour)),
          isTrue);
      expect(
          split.closed.every(
              (a) => !hours.isOpenAt(weekdayIndex(a.localDate), a.localHour)),
          isTrue);
      expect(split.open.length + split.closed.length, 48);
    });

    test('nothing is after-hours when the feature is off', () {
      final rows = [for (var i = 0; i < 24; i++) h('2026-07-19', i)];
      final split = splitByOpening(rows, OpeningHours.disabled);
      expect(split.closed, isEmpty);
      expect(split.open, hasLength(24));
    });
  });
}
