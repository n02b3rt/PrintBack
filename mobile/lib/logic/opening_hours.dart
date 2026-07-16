import '../models/aggregate.dart';

/// The shop's opening hours, in the operator's local clock.
///
/// One range for the whole week on purpose: a per-weekday schedule is a lot
/// of UI for a setting whose only job here is to stop the night from
/// polluting the numbers. If a shop really needs per-day hours, that's a
/// later problem worth its own design, not a checkbox grid bolted on now.
///
/// Hours are half-open `[open, close)` and may wrap midnight, so a bar open
/// 22:00-04:00 works without special-casing at the call sites.
class OpeningHours {
  /// When off, everything counts as open - the honest default for someone
  /// who never set it up. No silent guessing at a shop's hours.
  final bool enabled;

  /// First open hour (0-23), inclusive.
  final int openHour;

  /// First closed hour (0-23), exclusive. Equal to [openHour] means 24h.
  final int closeHour;

  const OpeningHours({
    this.enabled = false,
    this.openHour = 8,
    this.closeHour = 20,
  });

  static const disabled = OpeningHours();

  bool isOpen(int localHour) {
    if (!enabled) return true;
    if (openHour == closeHour) return true; // open around the clock
    if (openHour < closeHour) {
      return localHour >= openHour && localHour < closeHour;
    }
    return localHour >= openHour || localHour < closeHour; // wraps midnight
  }

  /// How many hours of the day the shop is open. Used to keep averages
  /// honest instead of dividing a day's visitors by 24.
  int get openHourCount {
    if (!enabled || openHour == closeHour) return 24;
    return openHour < closeHour
        ? closeHour - openHour
        : 24 - openHour + closeHour;
  }

  OpeningHours copyWith({bool? enabled, int? openHour, int? closeHour}) =>
      OpeningHours(
        enabled: enabled ?? this.enabled,
        openHour: openHour ?? this.openHour,
        closeHour: closeHour ?? this.closeHour,
      );

  @override
  bool operator ==(Object other) =>
      other is OpeningHours &&
      other.enabled == enabled &&
      other.openHour == openHour &&
      other.closeHour == closeHour;

  @override
  int get hashCode => Object.hash(enabled, openHour, closeHour);
}

/// Splits hourly rows into what happened while open and what happened after
/// hours. Keyed on [Aggregate.localHour] - the operator's wall clock, not the
/// UTC the wire carries (docs/LEARNINGS.md 2026-07-11).
({List<Aggregate> open, List<Aggregate> closed}) splitByOpening(
    List<Aggregate> hourly, OpeningHours hours) {
  final open = <Aggregate>[];
  final closed = <Aggregate>[];
  for (final a in hourly) {
    (hours.isOpen(a.localHour) ? open : closed).add(a);
  }
  return (open: open, closed: closed);
}
