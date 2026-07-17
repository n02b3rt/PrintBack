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

/// Drops the day the device was switched on from [rows].
///
/// That day only ever covers part of a day - nobody plugs the thing in at
/// midnight - so it lands in the history as a near-empty day that isn't one.
/// Left in, it drags a trend line down to the floor, pulls the daily average
/// under, and poisons "a typical Tuesday" if it happens to be a Tuesday. It's
/// real data, but it answers a different question ("how many people between
/// 3pm and closing") than every other row ("how many people that day"), and
/// averaging the two together is what makes the number wrong.
///
/// [installDate] is the oldest date the *cache* holds (LocalDb.
/// oldestDailyDate), not the oldest date in [rows] - a period like "last 7
/// days" has its own first row, which is an ordinary complete day.
///
/// Never strips the last row standing: on day one that would leave a screen
/// with nothing on it, and "no data yet" is already handled elsewhere with
/// better words than an empty chart.
List<Aggregate> withoutInstallDay(List<Aggregate> rows, String? installDate) {
  if (installDate == null) return rows;
  final kept = rows.where((a) => a.date != installDate).toList();
  return kept.isEmpty ? rows : kept;
}

/// Just the rows falling on [weekday] (0=Monday), oldest first.
///
/// The weekday-pattern chart answers "which day is busiest"; this answers the
/// question that comes straight after it - "are my Tuesdays getting better or
/// worse?" - which the pattern chart can't, because it has already averaged
/// the time dimension away.
List<Aggregate> onlyWeekday(List<Aggregate> daily, int weekday) {
  final rows = daily.where((a) => weekdayIndex(a.date) == weekday).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return rows;
}

/// Trailing moving average of [values] over [window] points.
///
/// Positions without a full window are null rather than a partial average:
/// a "7-day average" computed from two days is not a 7-day average, and on a
/// chart it would draw a confident line through the noisiest part of the
/// history. The caller skips the nulls, so the smoothed line simply starts
/// once it means something.
List<double?> movingAverage(List<int> values, int window) {
  if (window <= 0) return List.filled(values.length, null);
  final out = <double?>[];
  var sum = 0;
  for (var i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= window) sum -= values[i - window];
    out.add(i >= window - 1 ? sum / window : null);
  }
  return out;
}

/// Average share of a day's visitors that has already arrived by the end of
/// local [hour], derived from past days' hourly rows.
///
/// Each day contributes `cumulative(0..hour) / that same day's hourly total`,
/// deliberately normalised against its *own* hourly total rather than against
/// its daily row. Hourly aggregates are k-anonymity gated - an hour under the
/// threshold is never published at all (docs/DATA_MODEL.md) - so the hourly
/// rows systematically under-count the day. Dividing by the daily total would
/// bake that shortfall into the curve and make "typical by now" far too low,
/// which would cheerfully report "busier than usual" on a perfectly ordinary
/// day. Normalising within the hourly data cancels the gap between numerator
/// and denominator, leaving the *shape* of the day, which is what's wanted.
///
/// Shape is taken across all weekdays, not just the matching one: there are
/// only ever a handful of same-weekday days in the hourly window, and when a
/// shop fills up over the day barely depends on which day it is - unlike the
/// daily *total*, which very much does.
///
/// Null when fewer than [minDays] usable days are present; the curve would be
/// noise.
double? typicalDayFraction(List<Aggregate> hourly, int hour,
    {int minDays = 2}) {
  final byDay = <String, List<Aggregate>>{};
  for (final a in hourly) {
    byDay.putIfAbsent(a.localDate, () => []).add(a);
  }
  final fractions = <double>[];
  for (final rows in byDay.values) {
    final total = rows.fold<int>(0, (s, a) => s + a.unique);
    if (total <= 0) continue;
    final upTo = rows
        .where((a) => a.localHour <= hour)
        .fold<int>(0, (s, a) => s + a.unique);
    fractions.add(upTo / total);
  }
  if (fractions.length < minDays) return null;
  return fractions.reduce((a, b) => a + b) / fractions.length;
}

enum PaceVerdict { above, typical, below }

/// "How is today going, compared to a normal `<weekday>` at this hour" - the
/// one thing an owner actually wants mid-shift.
class DayPace {
  /// Today's running total so far.
  final int soFar;

  /// What a typical same-weekday has usually delivered by this hour.
  final int typicalByNow;

  /// What a typical same-weekday delivers by closing time.
  final int typicalFullDay;

  final PaceVerdict verdict;

  /// Percent difference of [soFar] vs [typicalByNow], null if no baseline.
  final int? deltaPercent;

  const DayPace({
    required this.soFar,
    required this.typicalByNow,
    required this.typicalFullDay,
    required this.verdict,
    required this.deltaPercent,
  });
}

/// Builds the "today vs a typical `<weekday>`" comparison, or null when there
/// isn't enough history to say anything honest.
///
/// [pastDaily] and [pastHourly] must exclude today (today's own numbers can't
/// be part of its own baseline). [todaySoFar] is today's running unique total
/// - the daily row, which the device always writes, not a sum of the gated
/// hourly ones. [hour] is the current local hour.
DayPace? computeDayPace({
  required List<Aggregate> pastDaily,
  required List<Aggregate> pastHourly,
  required int todaySoFar,
  required int todayWeekday,
  required int hour,
  int minSameWeekdays = 2,
  int thresholdPct = 15,
}) {
  final sameWeekday =
      pastDaily.where((a) => weekdayIndex(a.date) == todayWeekday).toList();
  if (sameWeekday.length < minSameWeekdays) return null;

  final typicalFull =
      sameWeekday.fold<int>(0, (s, a) => s + a.unique) / sameWeekday.length;
  final fraction = typicalDayFraction(pastHourly, hour);
  if (fraction == null || fraction <= 0) return null;

  final byNow = (typicalFull * fraction).round();
  if (byNow <= 0) return null;

  final delta = deltaPercent(todaySoFar, byNow);
  final PaceVerdict verdict;
  if (delta == null) {
    verdict = PaceVerdict.typical;
  } else if (delta >= thresholdPct) {
    verdict = PaceVerdict.above;
  } else if (delta <= -thresholdPct) {
    verdict = PaceVerdict.below;
  } else {
    verdict = PaceVerdict.typical;
  }

  return DayPace(
    soFar: todaySoFar,
    typicalByNow: byNow,
    typicalFullDay: typicalFull.round(),
    verdict: verdict,
    deltaPercent: delta,
  );
}
