import '../models/aggregate.dart';
import 'stats_math.dart';

/// A single plain-language takeaway about footfall. The screen maps [kind]
/// (+ [percent] for up/down) onto a localized one-sentence string - the
/// logic stays pure and testable, the wording lives in the UI/l10n.
enum InsightKind { record, up, down, quiet }

class Insight {
  final InsightKind kind;

  /// Magnitude in percent for [InsightKind.up]/[InsightKind.down], else 0.
  final int percent;

  const Insight(this.kind, {this.percent = 0});

  @override
  bool operator ==(Object other) =>
      other is Insight && other.kind == kind && other.percent == percent;

  @override
  int get hashCode => Object.hash(kind, percent);
}

/// Builds up to [limit] notable insights from finalized daily aggregates,
/// most notable first. Pure - no UI, no db, no clock.
///
/// [daily] must be **complete** days (the caller excludes today's partial
/// running total, so a half-finished day never reads as a "quiet" drop).
/// The reference is the most recent day in the list; rules:
///  - **record**: it's the period's highest (needs >= 3 days of history);
///  - **up/down**: >= 15% above/below the average of the *same weekday*
///    over the rest of the history (needs >= 2 same-weekday samples);
///  - **quiet**: well below the overall average, only if nothing else fired.
List<Insight> buildInsights(List<Aggregate> daily, {int limit = 2}) {
  if (daily.isEmpty) return const [];
  final rows = [...daily]..sort((a, b) => a.date.compareTo(b.date));
  final latest = rows.last;
  if (latest.unique <= 0) return const [];

  final insights = <Insight>[];

  final maxUnique = rows.map((r) => r.unique).reduce((a, b) => a > b ? a : b);
  if (rows.length >= 3 && latest.unique == maxUnique) {
    insights.add(const Insight(InsightKind.record));
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

  if (insights.isEmpty && rows.length >= 3) {
    final overallAvg =
        rows.map((r) => r.unique).reduce((a, b) => a + b) / rows.length;
    if (overallAvg > 0 && latest.unique < overallAvg * 0.6) {
      insights.add(const Insight(InsightKind.quiet));
    }
  }

  return insights.take(limit).toList();
}
