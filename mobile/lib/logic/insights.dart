import '../models/aggregate.dart';
import 'stats_math.dart';

/// A single plain-language takeaway about footfall. The screen maps [kind]
/// (+ the numbers below) onto a localized one-sentence string - the logic
/// stays pure and testable, the wording lives in the UI/l10n.
enum InsightKind {
  /// The latest day is the highest in the whole history given.
  record,

  /// Notably above the average of the same weekday.
  up,

  /// Notably below the average of the same weekday.
  down,

  /// Several days in a row above the overall average.
  streak,

  /// Beat most of the recent same-weekdays ("better than 8 of the last 10
  /// Tuesdays") - the same comparison as [up], but phrased as a rank, which
  /// reads far more intuitively than a percentage.
  percentile,

  /// Well below the overall average; only used when nothing else fired.
  quiet,
}

class Insight {
  final InsightKind kind;

  /// Magnitude in percent for [InsightKind.up]/[InsightKind.down], else 0.
  final int percent;

  /// Streak length for [InsightKind.streak]; how many days were beaten for
  /// [InsightKind.percentile]. Zero otherwise.
  final int count;

  /// The comparison set size for [InsightKind.percentile]. Zero otherwise.
  final int total;

  const Insight(this.kind, {this.percent = 0, this.count = 0, this.total = 0});

  @override
  bool operator ==(Object other) =>
      other is Insight &&
      other.kind == kind &&
      other.percent == percent &&
      other.count == count &&
      other.total == total;

  @override
  int get hashCode => Object.hash(kind, percent, count, total);
}

/// Builds up to [limit] notable insights from finalized daily aggregates,
/// most notable first. Pure - no UI, no db, no clock.
///
/// [daily] must be **complete** days (the caller excludes today's partial
/// running total, so a half-finished day never reads as a "quiet" drop).
/// The reference is the most recent day in the list. Rules, in notability
/// order:
///  - **record**: it's the highest in the history given (needs >= 3 days);
///  - **streak**: it caps >= 3 consecutive days above the overall average;
///  - **up/down**: >= 15% above/below the average of the *same weekday*
///    over the rest of the history (needs >= 2 same-weekday samples);
///  - **percentile**: it beat >= 70% of the recent same-weekdays (needs >= 4);
///  - **quiet**: well below the overall average, only if nothing else fired.
///
/// More rules can fire than [limit] allows. Rather than always showing the
/// same top two, [rotationSeed] rotates which of the *secondary* ones get a
/// slot - the single most notable insight always keeps the first slot, so
/// rotation adds variety without ever burying the headline. Pass something
/// stable within a day (the day-of-year) so the card doesn't reshuffle on
/// every rebuild but does look different tomorrow.
List<Insight> buildInsights(List<Aggregate> daily,
    {int limit = 2, int rotationSeed = 0}) {
  if (daily.isEmpty || limit <= 0) return const [];
  final rows = [...daily]..sort((a, b) => a.date.compareTo(b.date));
  final latest = rows.last;
  if (latest.unique <= 0) return const [];

  final insights = <Insight>[];
  final overallAvg =
      rows.map((r) => r.unique).reduce((a, b) => a + b) / rows.length;

  final maxUnique = rows.map((r) => r.unique).reduce((a, b) => a > b ? a : b);
  if (rows.length >= 3 && latest.unique == maxUnique) {
    insights.add(const Insight(InsightKind.record));
  }

  // Streak: how many days, counting back from the latest, stayed above the
  // overall average. Only interesting once it's a real run.
  if (rows.length >= 3 && overallAvg > 0) {
    var streak = 0;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i].unique > overallAvg) {
        streak++;
      } else {
        break;
      }
    }
    if (streak >= 3) {
      insights.add(Insight(InsightKind.streak, count: streak));
    }
  }

  final wd = weekdayIndex(latest.date);
  final sameWeekday = [
    for (final r in rows)
      if (r != latest && weekdayIndex(r.date) == wd) r.unique
  ];

  if (sameWeekday.length >= 2) {
    final avg = sameWeekday.reduce((a, b) => a + b) / sameWeekday.length;
    if (avg > 0) {
      final pct = ((latest.unique / avg - 1) * 100).round();
      if (pct >= 15) {
        insights.add(Insight(InsightKind.up, percent: pct));
      } else if (pct <= -15) {
        insights.add(Insight(InsightKind.down, percent: -pct));
      }
    }
  }

  // Rank against the same weekday reads better than a percentage once
  // there's a real sample to rank against.
  if (sameWeekday.length >= 4) {
    final beaten = sameWeekday.where((u) => latest.unique > u).length;
    if (beaten / sameWeekday.length >= 0.7) {
      insights.add(Insight(InsightKind.percentile,
          count: beaten, total: sameWeekday.length));
    }
  }

  if (insights.isEmpty && rows.length >= 3) {
    if (overallAvg > 0 && latest.unique < overallAvg * 0.6) {
      insights.add(const Insight(InsightKind.quiet));
    }
  }

  if (insights.length <= limit) return insights;

  // Headline stays put; the remaining slots rotate through the rest.
  final picks = <Insight>[insights.first];
  final tail = insights.skip(1).toList();
  for (var i = 0; i < limit - 1 && i < tail.length; i++) {
    picks.add(tail[(rotationSeed + i) % tail.length]);
  }
  return picks;
}
