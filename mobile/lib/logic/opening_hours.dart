import '../models/aggregate.dart';
import 'stats_math.dart';

/// One weekday's hours.
///
/// Half-open `[open, close)`, and may wrap midnight, so a bar open
/// 22:00-04:00 needs no special-casing at the call sites. [closed] is its own
/// flag rather than an empty range: "shut on Sunday" and "open 0-0" are
/// different facts, and a shop that is genuinely closed all day must not have
/// its Sunday traffic quietly counted as trading hours.
class DaySchedule {
  final bool closed;
  final int openHour;
  final int closeHour;

  const DaySchedule({
    this.closed = false,
    this.openHour = 8,
    this.closeHour = 20,
  });

  bool isOpen(int localHour) {
    if (closed) return false;
    if (openHour == closeHour) return true; // around the clock
    if (openHour < closeHour) {
      return localHour >= openHour && localHour < closeHour;
    }
    return localHour >= openHour || localHour < closeHour; // wraps midnight
  }

  int get openHourCount {
    if (closed) return 0;
    if (openHour == closeHour) return 24;
    return openHour < closeHour
        ? closeHour - openHour
        : 24 - openHour + closeHour;
  }

  DaySchedule copyWith({bool? closed, int? openHour, int? closeHour}) =>
      DaySchedule(
        closed: closed ?? this.closed,
        openHour: openHour ?? this.openHour,
        closeHour: closeHour ?? this.closeHour,
      );

  @override
  bool operator ==(Object other) =>
      other is DaySchedule &&
      other.closed == closed &&
      other.openHour == openHour &&
      other.closeHour == closeHour;

  @override
  int get hashCode => Object.hash(closed, openHour, closeHour);
}

/// The shop's week, one [DaySchedule] per weekday (index 0 = Monday, matching
/// [weekdayIndex]).
///
/// A single range for the whole week was the first cut of this and it was
/// wrong about ordinary shops, not just exotic ones: closed Sundays, a short
/// Saturday, one day off midweek. Those aren't edge cases to defer, they're
/// most high streets - and getting them wrong feeds the night, or a closed
/// day, straight into the averages the operator is judging their business by.
class OpeningHours {
  /// When off, everything counts as open - the honest default for someone who
  /// never set it up. No guessing at a shop's hours.
  final bool enabled;

  /// Exactly 7 entries, Monday first.
  final List<DaySchedule> days;

  const OpeningHours({this.enabled = false, required this.days});

  static const _defaultWeek = [
    DaySchedule(),
    DaySchedule(),
    DaySchedule(),
    DaySchedule(),
    DaySchedule(),
    DaySchedule(),
    DaySchedule(closed: true), // Sunday - the common Polish default
  ];

  static const disabled = OpeningHours(enabled: false, days: _defaultWeek);
  static const defaults = OpeningHours(enabled: true, days: _defaultWeek);

  /// [weekday] is 0=Monday .. 6=Sunday.
  bool isOpenAt(int weekday, int localHour) {
    if (!enabled) return true;
    return days[weekday].isOpen(localHour);
  }

  /// Open hours on [weekday]; 24 when the feature is off, so callers dividing
  /// by it don't have to special-case the default.
  int openHourCountOn(int weekday) => enabled ? days[weekday].openHourCount : 24;

  OpeningHours copyWithDay(int weekday, DaySchedule day) => OpeningHours(
        enabled: enabled,
        days: [
          for (var i = 0; i < 7; i++) i == weekday ? day : days[i],
        ],
      );

  OpeningHours copyWith({bool? enabled}) =>
      OpeningHours(enabled: enabled ?? this.enabled, days: days);

  @override
  bool operator ==(Object other) =>
      other is OpeningHours &&
      other.enabled == enabled &&
      _listEq(other.days, days);

  static bool _listEq(List<DaySchedule> a, List<DaySchedule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(days));
}

/// Splits hourly rows into what happened while open and what happened after
/// hours, using each row's own weekday - so a Sunday row is judged against
/// Sunday's schedule, not against a week-wide guess.
///
/// Keyed on [Aggregate.localHour]/[Aggregate.localDate] - the operator's wall
/// clock, not the UTC the wire carries (docs/LEARNINGS.md 2026-07-11).
({List<Aggregate> open, List<Aggregate> closed}) splitByOpening(
    List<Aggregate> hourly, OpeningHours hours) {
  final open = <Aggregate>[];
  final closed = <Aggregate>[];
  for (final a in hourly) {
    final weekday = weekdayIndex(a.localDate);
    (hours.isOpenAt(weekday, a.localHour) ? open : closed).add(a);
  }
  return (open: open, closed: closed);
}
