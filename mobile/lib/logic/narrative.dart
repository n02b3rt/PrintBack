import '../models/aggregate.dart';
import 'stats_math.dart';

/// The facts behind the plain-language paragraph on the statistics screen -
/// "Best day: Saturday (78). Traffic is up 12% on the previous week.
/// Returning visitors were 41%, six points more than before."
///
/// Pure numbers only: which sentences get written, in which language, and
/// which ones are worth writing at all is the screen's job (l10n). Same
/// split as [buildInsights] - no templates in here, no maths up there.
class PeriodNarrative {
  /// Total unique visitors across the period.
  final int total;

  /// Weekday (0=Monday) and size of the period's busiest day. Null when the
  /// period has no days with visitors.
  final int? bestDayWeekday;
  final int? bestDayCount;

  /// Percent change of [total] against the previous period of equal length,
  /// or null when there's no previous period to compare against.
  final int? deltaPercent;

  /// Share of visitors that were returning, 0-100.
  final int returningPct;

  /// Change in that share against the previous period, in percentage
  /// *points* (41% vs 35% is +6, not +17%) - a percentage of a percentage
  /// reads as nonsense to a shop owner. Null without a previous period.
  final int? returningDeltaPoints;

  const PeriodNarrative({
    required this.total,
    required this.bestDayWeekday,
    required this.bestDayCount,
    required this.deltaPercent,
    required this.returningPct,
    required this.returningDeltaPoints,
  });
}

/// Builds the narrative facts for [current] against [previous] (the same
/// span, immediately before). Null when the period has nothing to say -
/// no visitors means no story, and an empty paragraph beats a fabricated one.
PeriodNarrative? buildPeriodNarrative(
    List<Aggregate> current, List<Aggregate> previous) {
  if (current.isEmpty) return null;
  final total = sumUnique(current);
  if (total <= 0) return null;

  final returning = sumReturning(current);
  final best = bestDay(current);

  int? returningDelta;
  int? delta;
  if (previous.isNotEmpty) {
    final prevTotal = sumUnique(previous);
    if (prevTotal > 0) {
      delta = deltaPercent(total, prevTotal);
      returningDelta = returningRate(total, returning) -
          returningRate(prevTotal, sumReturning(previous));
    }
  }

  return PeriodNarrative(
    total: total,
    bestDayWeekday: best == null ? null : weekdayIndex(best.date),
    bestDayCount: best?.unique,
    deltaPercent: delta,
    returningPct: returningRate(total, returning),
    returningDeltaPoints: returningDelta,
  );
}
