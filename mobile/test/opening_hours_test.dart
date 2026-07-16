import 'package:flutter_test/flutter_test.dart';
import 'package:printback/logic/opening_hours.dart';
import 'package:printback/models/aggregate.dart';

void main() {
  group('isOpen', () {
    test('everything is open when the setting is off', () {
      const h = OpeningHours(enabled: false, openHour: 8, closeHour: 20);
      for (var i = 0; i < 24; i++) {
        expect(h.isOpen(i), isTrue, reason: 'hour $i');
      }
    });

    test('a normal daytime range is half-open', () {
      const h = OpeningHours(enabled: true, openHour: 8, closeHour: 20);
      expect(h.isOpen(7), isFalse);
      expect(h.isOpen(8), isTrue); // opening hour counts
      expect(h.isOpen(19), isTrue);
      expect(h.isOpen(20), isFalse); // closing hour does not
    });

    test('a range that wraps midnight still works', () {
      const h = OpeningHours(enabled: true, openHour: 22, closeHour: 4);
      expect(h.isOpen(22), isTrue);
      expect(h.isOpen(23), isTrue);
      expect(h.isOpen(0), isTrue);
      expect(h.isOpen(3), isTrue);
      expect(h.isOpen(4), isFalse);
      expect(h.isOpen(12), isFalse);
    });

    test('equal open and close means around the clock', () {
      const h = OpeningHours(enabled: true, openHour: 0, closeHour: 0);
      expect(h.isOpen(3), isTrue);
      expect(h.isOpen(15), isTrue);
    });
  });

  group('openHourCount', () {
    test('counts a daytime range', () {
      expect(const OpeningHours(enabled: true, openHour: 8, closeHour: 20)
          .openHourCount, 12);
    });

    test('counts a range across midnight', () {
      expect(const OpeningHours(enabled: true, openHour: 22, closeHour: 4)
          .openHourCount, 6);
    });

    test('is the whole day when disabled or 24h', () {
      expect(const OpeningHours(enabled: false).openHourCount, 24);
      expect(const OpeningHours(enabled: true, openHour: 9, closeHour: 9)
          .openHourCount, 24);
    });
  });

  group('splitByOpening', () {
    Aggregate h(int hour) => Aggregate(
        date: '2026-07-14', hour: hour, unique: 5, returning: 0, kanon: false);

    test('separates after-hours rows from open ones', () {
      // localHour is a UTC->local conversion, so build the expectation from
      // the rows themselves rather than hardcoding hours (CI runs in UTC).
      final rows = [for (var i = 0; i < 24; i++) h(i)];
      const hours = OpeningHours(enabled: true, openHour: 8, closeHour: 20);
      final split = splitByOpening(rows, hours);

      expect(split.open.every((a) => hours.isOpen(a.localHour)), isTrue);
      expect(split.closed.every((a) => !hours.isOpen(a.localHour)), isTrue);
      expect(split.open.length + split.closed.length, 24);
      expect(split.open, hasLength(12));
    });

    test('nothing is after-hours when the setting is off', () {
      final rows = [for (var i = 0; i < 24; i++) h(i)];
      final split = splitByOpening(rows, OpeningHours.disabled);
      expect(split.closed, isEmpty);
      expect(split.open, hasLength(24));
    });
  });
}
