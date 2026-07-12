import '../models/aggregate.dart';

/// Pure statistics helpers, extracted from the dashboard/statistics
/// widgets so the maths can be unit-tested independently of the UI (the
/// screens now call these instead of computing inline). No BLE, no db, no
/// widgets - just numbers in, numbers out. This is also the foundation the
/// later "insights" card (Etap 5) builds on.

int sumUnique(List<Aggregate> rows) =>
    rows.fold(0, (s, a) => s + a.unique);

int sumReturning(List<Aggregate> rows) =>
    rows.fold(0, (s, a) => s + a.returning);

/// Percent change of [current] vs [previous], or null when there's no
/// previous baseline to compare against (division by zero would be
/// meaningless, not "infinite growth").
int? deltaPercent(int current, int previous) =>
    previous == 0 ? null : ((current - previous) * 100 / previous).round();

/// Share of visitors that were returning, 0-100. Zero when there were no
/// visitors at all (not a divide-by-zero).
int returningRate(int totalUnique, int totalReturning) =>
    totalUnique == 0 ? 0 : (totalReturning * 100 / totalUnique).round();

/// Mean visitors per day over [days], rounded. Zero for an empty period.
int averagePerDay(int totalUnique, int days) =>
    days == 0 ? 0 : (totalUnique / days).round();

/// Weekday index 0=Monday .. 6=Sunday for a `YYYY-MM-DD` date. Uses UTC to
/// match how the aggregates are dated on the wire (docs/DATA_MODEL.md).
int weekdayIndex(String isoDate) {
  final p = isoDate.split('-');
  return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]))
          .weekday -
      1;
}

/// Average unique per weekday (index 0=Monday..6=Sunday); a weekday with
/// no data reads 0.
List<double> weekdayAverages(List<Aggregate> daily) {
  final sums = List<int>.filled(7, 0);
  final counts = List<int>.filled(7, 0);
  for (final a in daily) {
    final idx = weekdayIndex(a.date);
    sums[idx] += a.unique;
    counts[idx]++;
  }
  return List.generate(7, (i) => counts[i] == 0 ? 0.0 : sums[i] / counts[i]);
}

/// The daily row with the most unique visitors, or null for empty input.
Aggregate? bestDay(List<Aggregate> daily) {
  Aggregate? best;
  for (final a in daily) {
    if (best == null || a.unique > best.unique) best = a;
  }
  return best;
}

/// The local hour (0-23) with the highest average unique across [hourly],
/// or null if there's no hourly data. Keyed by Aggregate.localHour.
int? peakHour(List<Aggregate> hourly) {
  final sums = List<int>.filled(24, 0);
  final counts = List<int>.filled(24, 0);
  for (final a in hourly) {
    sums[a.localHour] += a.unique;
    counts[a.localHour]++;
  }
  int? peak;
  var peakAvg = -1.0;
  for (var h = 0; h < 24; h++) {
    if (counts[h] == 0) continue;
    final avg = sums[h] / counts[h];
    if (avg > peakAvg) {
      peakAvg = avg;
      peak = h;
    }
  }
  return peak;
}

/// How many distinct local calendar days have any hourly data - used to
/// caption the peak-hour stat honestly ("based on N days") since hourly
/// history is only as complete as past live connections happened to make
/// it (docs/DATA_MODEL.md).
int daysWithHourlyData(List<Aggregate> hourly) =>
    hourly.map((a) => a.localDate).toSet().length;

/// How a single value compares to a period average, for the tap-to-detail
/// interpretation line. [isExtreme] is the screen's own "this is the
/// peak/best" test (the screen picks the wording, since "peak hour" and
/// "best day" differ); the maths only classifies the magnitude.
enum TrendClass { extreme, above, below, around }

class TrendResult {
  final TrendClass cls;

  /// Magnitude in percent for [TrendClass.above]/[TrendClass.below], else 0.
  final int percent;

  const TrendResult(this.cls, this.percent);
}

TrendResult classifyTrend(num value, double average, {required bool isExtreme}) {
  if (isExtreme) return const TrendResult(TrendClass.extreme, 0);
  if (average > 0 && value > average * 1.2) {
    return TrendResult(
        TrendClass.above, ((value / average - 1) * 100).round());
  }
  if (average > 0 && value < average * 0.8) {
    return TrendResult(
        TrendClass.below, ((1 - value / average) * 100).round());
  }
  return const TrendResult(TrendClass.around, 0);
}
