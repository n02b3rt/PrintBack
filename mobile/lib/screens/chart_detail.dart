import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/narrative.dart';
import '../logic/opening_hours.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import '../storage/opening_hours_store.dart';
import '../widgets/chart_stats.dart';
import '../widgets/chart_style.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';

/// Which question a drill-down is for.
///
/// One screen used to try to answer both, and the seam showed: tapping the
/// hourly "today" chart opened a seven-day view still captioned "today"
/// (2026-07-17). "How is today going" and "where is this heading" want
/// different periods, different resolutions and different comparisons, so they
/// get their own range sets rather than one list that half-fits each.
enum ChartDetailMode {
  /// Near-term, at hour resolution: today, yesterday, the last week.
  recent,

  /// The long view, at day resolution: a week, a month, everything.
  trend,
}

enum _Range { today, yesterday, d7, d30, max }

/// How much history one point covers. Picked from the range and how much
/// data actually exists, not fixed per range: four days of daily rows is a
/// four-dot chart nobody would call a trend, and a year of them is a smear.
enum _Gran { hourly, daily, weekly }

/// One point on the trend, whatever it's aggregated from.
///
/// [x] is a position on a real timeline (hours or days since the range
/// started), not a list index - so a missing hour leaves a hole the chart can
/// break the line across, rather than being silently closed up as if the time
/// never happened.
class _PlotPoint {
  final double x;
  final int unique;
  final int returning;

  /// Short form for the x-axis.
  final String axisLabel;

  /// The point's own date, and its hour when the point is an hour. Kept as
  /// data rather than a pre-baked string so the header can format it in the
  /// app's language ("czwartek, 16 lipca") instead of showing the axis's
  /// terse "16.07".
  final String isoDate;
  final int? hour;

  /// An hour the device never published because it fell under the
  /// k-anonymity threshold. Not "no data" - the device is telling us it was
  /// fewer than five, we just don't get the exact number. Plotted at zero
  /// (which can only ever understate by four) and read out as "<5" rather
  /// than as a count we'd be inventing.
  final bool belowThreshold;

  const _PlotPoint({
    required this.x,
    required this.unique,
    required this.returning,
    required this.axisLabel,
    required this.isoDate,
    this.hour,
    this.belowThreshold = false,
  });

  int get newVisitors => (unique - returning).clamp(0, unique);
}

/// Extra series the operator can lay over the visitors line. Visitors itself
/// is always drawn - it's what the headline counts, so a chart without it
/// would describe something the header doesn't.
enum _Series { returning, newVisitors }

/// Full-screen drill-down for the daily trend: the period's headline number
/// and how it compares, a scrubbable line, optional overlays, the same
/// plain-language interpretation the statistics screen uses, and the stats
/// grid.
///
/// The panel's chart cards carry a three-number strip (widgets/chart_stats.
/// dart); this is that idea with room to breathe. Everything here is computed
/// from aggregates already in the local cache - opening it needs no device
/// and no connection.
class ChartDetail extends StatefulWidget {
  final String deviceId;
  final ChartDetailMode mode;

  const ChartDetail({
    super.key,
    required this.deviceId,
    required this.mode,
  });

  @override
  State<ChartDetail> createState() => _ChartDetailState();
}

class _ChartDetailState extends State<ChartDetail> {
  final _localDb = LocalDb();

  /// The ranges this mode offers, and where it opens. A drill-down opens on
  /// the period that was tapped to get here: the hourly card means today, the
  /// trend card means the month.
  List<_Range> get _ranges => switch (widget.mode) {
        ChartDetailMode.recent => const [
            _Range.today,
            _Range.yesterday,
            _Range.d7
          ],
        ChartDetailMode.trend => const [_Range.d7, _Range.d30, _Range.max],
      };

  late _Range _range =
      widget.mode == ChartDetailMode.recent ? _Range.today : _Range.d30;
  final Set<_Series> _series = {};
  bool _showPrevious = false;
  bool _showAverage = true;


  List<Aggregate> _rows = [];
  List<Aggregate> _previous = [];
  List<_PlotPoint> _points = [];
  _Gran _gran = _Gran.daily;
  bool _loading = true;

  /// Only used to shade the closed hours behind the line. Defaults to
  /// `disabled`, which shades nothing - if the operator never set opening
  /// hours, the chart has no business claiming to know when they're shut.
  OpeningHours _hours = OpeningHours.disabled;

  /// Where the current window starts, kept from the last load so the closed
  /// bands can turn an x back into a real hour of a real weekday.
  DateTime _windowStart = DateTime.now();

  /// "Today vs a typical same-weekday at this hour", for the today range only.
  /// Null when there isn't enough same-weekday history to say it honestly -
  /// [computeDayPace] returns null rather than guess, and so do we.
  DayPace? _pace;

  /// Which point the finger is on, or null when nobody's touching the chart.
  /// Dragging rewrites the header instead of popping a tooltip over the line:
  /// the number is already the biggest thing on the screen, so putting the
  /// scrubbed value there means the eye never leaves it, and nothing covers
  /// the chart you're reading.
  int? _scrub;

  @override
  void initState() {
    super.initState();
    _loadHours();
    _load();
  }

  Future<void> _loadHours() async {
    final h = await OpeningHoursStore.load();
    if (mounted) setState(() => _hours = h);
  }

  /// How many days the range covers, or null for "everything" (which has no
  /// earlier period to compare against).
  int? get _rangeDays => switch (_range) {
        _Range.today || _Range.yesterday => 1,
        _Range.d7 => 7,
        _Range.d30 => 30,
        _Range.max => null,
      };

  bool get _isSingleDay =>
      _range == _Range.today || _range == _Range.yesterday;

  /// The local calendar days a range covers, inclusive at both ends.
  (DateTime, DateTime) get _window {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    return switch (_range) {
      _Range.today => (today, today),
      _Range.yesterday => (yesterday, yesterday),
      _Range.d7 => (today.subtract(const Duration(days: 6)), today),
      _Range.d30 => (today.subtract(const Duration(days: 29)), today),
      // Far enough back to mean "whatever the cache holds".
      _Range.max => (DateTime(2000), today),
    };
  }

  /// Resolution follows the range, and for the open-ended one, the data.
  ///
  /// A single day is only ever worth reading by the hour. A week of daily rows
  /// is seven dots - technically a trend, practically a shrug - so it drops to
  /// hours too, where there are ~24x as many points. A long history goes the
  /// other way: 200 daily dots at 3px apart is a smear nobody can scrub, so it
  /// rolls up to weeks.
  _Gran _granFor(_Range range, int dailyRowCount) => switch (range) {
        _Range.today || _Range.yesterday || _Range.d7 => _Gran.hourly,
        _Range.d30 => _Gran.daily,
        _Range.max => dailyRowCount > 90 ? _Gran.weekly : _Gran.daily,
      };

  String _rangeLabel(AppLocalizations l10n, _Range r) => switch (r) {
        _Range.today => l10n.rangeToday,
        _Range.yesterday => l10n.rangeYesterday,
        _Range.d7 => l10n.range7d,
        _Range.d30 => l10n.range30d,
        _Range.max => l10n.rangeMax,
      };

  Future<void> _load() async {
    setState(() => _loading = true);
    final days = _rangeDays;
    final (start, end) = _window;

    final ordered = await _localDb.dailyInRange(
        widget.deviceId, _fmt(start), _fmt(end));

    // Two ranges get no baseline, for different reasons. "Everything" has no
    // earlier period left to compare against at all. "Today" has one, but it
    // isn't a fair fight: a day that is twelve hours old against a complete
    // one reads as a 47% collapse at noon and recovers only because the clock
    // moves - the same partial-day distortion that keeps today out of reports.
    // The header drops the delta rather than showing a number that's wrong
    // until midnight, and the note under the range picker says why.
    List<Aggregate> previous = const [];
    if (days != null && _range != _Range.today) {
      final prevEnd = start.subtract(const Duration(days: 1));
      final prevStart = prevEnd.subtract(Duration(days: days - 1));
      previous = await _localDb.dailyInRange(
          widget.deviceId, _fmt(prevStart), _fmt(prevEnd));
    }

    // Today can't be compared against a whole previous day, but it *can* be
    // compared against how a typical same-weekday looks by this hour, which is
    // the actual question ("is today going well?") and the one the header has
    // room for once the bogus delta is gone.
    DayPace? pace;
    if (_range == _Range.today) {
      final todayIso = _fmt(start);
      final pastDaily = (await _localDb.recentDaily(widget.deviceId, limit: 30))
          .where((a) => a.date != todayIso)
          .toList();
      final pastHourly = (await _localDb.hourlyInRange(
        widget.deviceId,
        _fmt(start.subtract(const Duration(days: 30))),
        todayIso,
      ))
          .where((a) => a.localDate != todayIso)
          .toList();
      pace = computeDayPace(
        pastDaily: pastDaily,
        pastHourly: pastHourly,
        todaySoFar: sumUnique(ordered),
        todayWeekday: weekdayIndex(todayIso),
        hour: DateTime.now().hour,
      );
    }

    var gran = _granFor(_range, ordered.length);

    List<_PlotPoint> points;
    if (gran == _Gran.hourly) {
      points = await _hourlyPoints(start, end);
      // No hourly history for this window (the device backfills a week, and a
      // fresh install has none) - a coarse answer beats a blank chart. A
      // single day has no daily fallback worth drawing, though: one dot is not
      // a chart, so it stays empty and the card says so.
      if (points.length < 2 && !_isSingleDay) {
        points = _dailyPoints(ordered);
        gran = _Gran.daily;
      }
    } else if (gran == _Gran.weekly) {
      points = _weeklyPoints(ordered);
    } else {
      points = _dailyPoints(ordered);
    }

    if (!mounted) return;
    setState(() {
      _rows = ordered;
      _previous = previous;
      _points = points;
      _gran = gran;
      _windowStart = start;
      _pace = pace;
      _loading = false;
      _scrub = null; // the old index means nothing against new points
    });
  }

  /// Shaded bands behind the line for the hours the place is shut.
  ///
  /// Without this, traffic at 03:00 reads as either a bug or a break-in. The
  /// device keeps sniffing around the clock (people walk past a closed shop),
  /// so the line is real - it just isn't custom, and the chart should say
  /// which is which instead of leaving the operator to work it out.
  ///
  /// Only drawn for hourly points, and only when opening hours are actually
  /// switched on: a band on a daily chart would be meaningless (a day isn't
  /// open or closed), and shading by some default nobody chose would invent a
  /// rule the operator never set.
  List<VerticalRangeAnnotation> _closedBands(Color color) {
    if (!_hours.enabled || _gran != _Gran.hourly || _points.isEmpty) {
      return const [];
    }
    final firstX = _points.first.x.round();
    final lastX = _points.last.x.round();
    final out = <VerticalRangeAnnotation>[];
    int? runStart;
    // One past the end so a run that reaches the last hour still gets closed.
    for (var h = firstX; h <= lastX + 1; h++) {
      final t = _windowStart.add(Duration(hours: h));
      // DateTime.weekday is 1=Monday; OpeningHours indexes 0=Monday.
      final closed =
          h <= lastX && !_hours.isOpenAt(t.weekday - 1, t.hour);
      if (closed) {
        runStart ??= h;
      } else if (runStart != null) {
        // Half-hour overhang each side so the band covers its hours rather
        // than stopping at their centres.
        out.add(VerticalRangeAnnotation(
            x1: runStart - 0.5, x2: h - 0.5, color: color));
        runStart = null;
      }
    }
    return out;
  }

  /// Hourly points across the range, positioned by real elapsed hours.
  ///
  /// Every hour between the first and last measurement gets a point, so the
  /// line is continuous. Hours the device never published are filled in at
  /// zero and flagged [_PlotPoint.belowThreshold]; the readout says "<5"
  /// for them rather than a number.
  ///
  /// The alternative - joining the published hours with a straight line -
  /// would run at whatever height the neighbours happen to be, claiming
  /// dozens of visitors in an hour the device is explicitly telling us had
  /// fewer than five. Filling at zero can only ever be four out, and the
  /// label says so. Hours *outside* the measured window are left alone: the
  /// device wasn't there, and a flat zero across days before it was plugged
  /// in would be a different lie.
  Future<List<_PlotPoint>> _hourlyPoints(DateTime start, DateTime end) async {
    // A day of padding each side, then filtered by local date - hourly rows
    // are dated UTC on the wire (docs/LEARNINGS.md 2026-07-11).
    final rows = await _localDb.hourlyInRange(
      widget.deviceId,
      _fmt(start.subtract(const Duration(days: 1))),
      _fmt(end.add(const Duration(days: 1))),
    );

    final startIso = _fmt(start);
    final endIso = _fmt(end);
    // On a single day the axis can carry the hour, which is the whole point of
    // that view. Across a week only about three labels fit, and "12:00" on a
    // seven-day chart doesn't say which day - so there it carries the date and
    // the hour lives in the scrub readout next to it.
    final single = _isSingleDay;

    final out = <_PlotPoint>[];
    for (final a in rows) {
      if (a.localDate.compareTo(startIso) < 0 ||
          a.localDate.compareTo(endIso) > 0) {
        continue;
      }
      final day = DateTime.tryParse(a.localDate);
      if (day == null) continue;
      final hoursFromStart = day.difference(start).inDays * 24 + a.localHour;
      if (hoursFromStart < 0) continue;
      out.add(_PlotPoint(
        x: hoursFromStart.toDouble(),
        unique: a.unique,
        returning: a.returning,
        axisLabel: single
            ? '${a.localHour.toString().padLeft(2, '0')}:00'
            : formatAxisDay(a.localDate),
        isoDate: a.localDate,
        hour: a.localHour,
      ));
    }
    out.sort((a, b) => a.x.compareTo(b.x));
    if (out.length < 2) return out;

    // Fill the holes inside the measured window.
    final byHour = {for (final p in out) p.x.round(): p};
    final firstX = out.first.x.round();
    final lastX = out.last.x.round();
    final filled = <_PlotPoint>[];
    for (var h = firstX; h <= lastX; h++) {
      final existing = byHour[h];
      if (existing != null) {
        filled.add(existing);
        continue;
      }
      final day = start.add(Duration(hours: h));
      filled.add(_PlotPoint(
        x: h.toDouble(),
        unique: 0,
        returning: 0,
        axisLabel: single
            ? '${day.hour.toString().padLeft(2, '0')}:00'
            : formatAxisDay(_fmt(day)),
        isoDate: _fmt(day),
        hour: day.hour,
        belowThreshold: true,
      ));
    }
    return filled;
  }

  List<_PlotPoint> _dailyPoints(List<Aggregate> rows) => [
        for (var i = 0; i < rows.length; i++)
          _PlotPoint(
            x: i.toDouble(),
            unique: rows[i].unique,
            returning: rows[i].returning,
            axisLabel: formatAxisDay(rows[i].date),
            isoDate: rows[i].date,
          ),
      ];

  /// Rolls daily rows up into calendar weeks (Monday-anchored), summing them.
  List<_PlotPoint> _weeklyPoints(List<Aggregate> rows) {
    final buckets = <String, List<Aggregate>>{};
    for (final a in rows) {
      final d = DateTime.tryParse(a.date);
      if (d == null) continue;
      final monday = d.subtract(Duration(days: d.weekday - 1));
      buckets.putIfAbsent(_fmt(monday), () => []).add(a);
    }
    final keys = buckets.keys.toList()..sort();
    return [
      for (var i = 0; i < keys.length; i++)
        _PlotPoint(
          x: i.toDouble(),
          unique: sumUnique(buckets[keys[i]]!),
          returning: sumReturning(buckets[keys[i]]!),
          axisLabel: formatAxisDay(keys[i]),
          isoDate: keys[i],
        ),
    ];
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// "o 41 więcej niż poprzednie 30 dni" - a count, not a percentage. A shop
  /// owner can picture 41 people; "+18%" is a number about a number.
  String _deltaSentence(AppLocalizations l10n) {
    final days = _rangeDays;
    if (days == null || _previous.isEmpty) return l10n.deltaNoBaseline;
    final diff = sumUnique(_rows) - sumUnique(_previous);
    // "than the previous 1 days" is not a sentence. A one-day range compares
    // against the day before, and says so.
    if (_isSingleDay) {
      if (diff == 0) return l10n.deltaSamePrevDay;
      return diff > 0
          ? l10n.deltaMorePrevDay(diff)
          : l10n.deltaFewerPrevDay(-diff);
    }
    if (diff == 0) return l10n.deltaSame(days);
    return diff > 0 ? l10n.deltaMore(diff, days) : l10n.deltaFewer(-diff, days);
  }

  /// Percent change against the previous period, or null when there isn't
  /// one. Shown next to the count, not instead of it: a percentage is what
  /// people scan for, a headcount is what they can actually picture, and
  /// Revolut shows both for the same reason.
  int? _deltaPct() {
    if (_rangeDays == null || _previous.isEmpty) return null;
    return deltaPercent(sumUnique(_rows), sumUnique(_previous));
  }

  /// The period summary, or - while a finger is on the chart - that day.
  ///
  /// Fixed height so the layout doesn't jump between the two states while
  /// scrubbing, which would make the chart shift under the finger.
  Widget _header(BuildContext context, AppLocalizations l10n, int total) {
    final theme = Theme.of(context);
    final i = _scrub;
    final scrubbed =
        (i != null && i >= 0 && i < _points.length) ? _points[i] : null;

    // A floor, not a fixed height: the two states must not make the layout
    // jump (the chart would shift under a scrubbing finger), but a hard
    // SizedBox silently clipped the number when the delta sentence wrapped
    // to two lines. Reserve the taller state's height and let it grow.
    final pct = _deltaPct();
    final up = (pct ?? 0) >= 0;
    final pctColor = pct == null || pct == 0
        ? theme.colorScheme.outline
        : (up ? theme.colorScheme.primary : theme.colorScheme.error);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 116),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // A suppressed hour reads "<5", not "0" - zero is where it's
            // drawn, not what the device measured.
            scrubbed == null
                ? '$total'
                : (scrubbed.belowThreshold
                    ? l10n.belowThresholdValue
                    : '${scrubbed.unique}'),
            style: theme.textTheme.displayMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            l10n.uniqueLabel,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 4),
          if (scrubbed != null)
            // Scrubbing: the date, plus whatever extra series are switched on
            // for that same day - otherwise turning "Powracający" on would
            // draw a line whose numbers you could never read.
            // Spelled out and given some weight: this line is the answer to
            // "what am I pointing at", so a terse "16.07, 15:00" in body text
            // made you decode the chart instead of reading it.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    formatDayTitle(scrubbed.isoDate, l10n.localeName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (scrubbed.hour != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${scrubbed.hour.toString().padLeft(2, '0')}:00',
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
                const Spacer(),
                if (_series.contains(_Series.returning))
                  _scrubChip(theme, l10n.returningLabel, scrubbed.returning,
                      theme.colorScheme.tertiary),
                if (_series.contains(_Series.newVisitors))
                  _scrubChip(theme, l10n.newVisitorsLabel, scrubbed.newVisitors,
                      theme.colorScheme.secondary),
              ],
            )
          // Today has no whole-day baseline (see _load), but the line can't
          // just go blank - the header reserves this row's height so the chart
          // doesn't shift under a scrubbing finger, and an empty reserved row
          // reads as something that failed to load. So: the pace verdict when
          // there's enough same-weekday history to mean it, and the day's own
          // date when there isn't. Both beat a hole, neither invents a trend.
          else if (_range == _Range.today)
            _todayLine(context, l10n)
          else
            Row(
              children: [
                if (pct != null && pct != 0) ...[
                  Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      size: 20, color: pctColor),
                  Text('${pct.abs()}%',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: pctColor, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(_deltaSentence(l10n),
                      style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// What sits where the delta line goes when the range is today.
  ///
  /// The pace verdict is the honest version of "how's today doing": it holds
  /// today's running total against how far a typical same-weekday has usually
  /// got by this hour, instead of against a finished day. When there aren't
  /// enough same-weekdays yet, [computeDayPace] gives null rather than guess,
  /// and the row falls back to naming the day - which is at least a fact, and
  /// tells you which Friday you're looking at.
  Widget _todayLine(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final pace = _pace;
    if (pace == null) {
      return Text(
        formatDayTitle(_fmt(_windowStart), l10n.localeName),
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.outline),
      );
    }

    final (String verdict, IconData icon, Color color) = switch (pace.verdict) {
      PaceVerdict.above => (
          l10n.paceAbove,
          Icons.trending_up,
          theme.colorScheme.primary
        ),
      PaceVerdict.below => (
          l10n.paceBelow,
          Icons.trending_down,
          theme.colorScheme.tertiary
        ),
      PaceVerdict.typical => (
          l10n.paceTypical,
          Icons.trending_flat,
          theme.colorScheme.outline
        ),
    };

    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            // The verdict, then what it's measured against - a verdict with no
            // baseline visible is just an adjective.
            '$verdict · ${l10n.paceByNowShort(pace.typicalByNow)}',
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// The day-based overlays are only meaningful while a point is a day.
  bool get _canOverlay => _gran == _Gran.daily;

  /// Colour swatch on a series chip, so the chip and its line are tied
  /// together without a separate legend.
  Widget? _seriesDot(Color color, bool on) => on
      ? null // the chip's own tick already says "on"
      : Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );

  Widget _scrubChip(ThemeData theme, String label, int value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text('$label $value',
              style: theme.textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final total = sumUnique(_rows);

    final title = switch (widget.mode) {
      ChartDetailMode.recent => l10n.chartDetailRecentTitle,
      ChartDetailMode.trend => l10n.chartDetailTrendTitle,
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: GradientBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _header(context, l10n, total),
                  const SizedBox(height: 16),
                  SegmentedButton<_Range>(
                    segments: [
                      for (final r in _ranges)
                        ButtonSegment(value: r, label: Text(_rangeLabel(l10n, r))),
                    ],
                    selected: {_range},
                    onSelectionChanged: (s) {
                      setState(() => _range = s.first);
                      _load();
                    },
                  ),
                  // Today's number is a running total, not a result. Without
                  // this the day reads as a bad day right up until it ends.
                  if (_range == _Range.today) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.todayPartialNote,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                  const SizedBox(height: 16),
                  GlassCard(
                    child: SizedBox(
                      height: 240,
                      child: _rows.isEmpty
                          ? Center(child: Text(l10n.emptyNoData))
                          : _TrendChart(
                              points: _points,
                              gran: _gran,
                              previous: _showPrevious ? _previous : const [],
                              showAverage: _showAverage,
                              series: _series,
                              closedBands: _closedBands(
                                  theme.colorScheme.onSurface
                                      .withValues(alpha: 0.06)),
                              onScrub: (i) {
                                if (i != _scrub) setState(() => _scrub = i);
                              },
                            ),
                    ),
                  ),
                  // A grey band nobody can explain is worse than no band. Say
                  // what the shading is, right under it, whenever it's drawn.
                  // Deliberately the same icon as the "<5" note below rather
                  // than a colour swatch: a small filled square with a border
                  // reads as an unchecked checkbox, which invites a tap that
                  // does nothing.
                  if (_closedBands(Colors.transparent).isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.nightlight_outlined,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(l10n.closedHoursLegend,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.outline)),
                        ),
                      ],
                    ),
                  ],
                  // Say it out loud rather than leaving it to whoever happens
                  // to scrub a quiet hour: part of this line is a floor, not
                  // a measurement.
                  if (_points.any((p) => p.belowThreshold)) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(l10n.belowThresholdHint,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.outline)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // Extra series first: these change what the chart is
                      // showing, the two below only annotate it.
                      FilterChip(
                        label: Text(l10n.returningLabel),
                        selected: _series.contains(_Series.returning),
                        avatar: _seriesDot(
                            theme.colorScheme.tertiary,
                            _series.contains(_Series.returning)),
                        onSelected: (v) => setState(() => v
                            ? _series.add(_Series.returning)
                            : _series.remove(_Series.returning)),
                      ),
                      FilterChip(
                        label: Text(l10n.newVisitorsLabel),
                        selected: _series.contains(_Series.newVisitors),
                        avatar: _seriesDot(
                            theme.colorScheme.secondary,
                            _series.contains(_Series.newVisitors)),
                        onSelected: (v) => setState(() => v
                            ? _series.add(_Series.newVisitors)
                            : _series.remove(_Series.newVisitors)),
                      ),
                      // Both overlays are defined in days, so they only mean
                      // something while the points are days. Over hourly
                      // points a "7-day average" would be an average of 7
                      // hours wearing the wrong label, and the ghost period
                      // wouldn't line up with the axis at all.
                      FilterChip(
                        label: Text(l10n.overlayPrevious),
                        selected: _showPrevious && _canOverlay,
                        onSelected: _previous.isEmpty || !_canOverlay
                            ? null
                            : (v) => setState(() => _showPrevious = v),
                      ),
                      FilterChip(
                        label: Text(l10n.overlayMovingAvg),
                        // A 7-day average of under 7 days is not one, so the
                        // overlay is unavailable then - and must not read as
                        // ticked while drawing nothing, which is what showing
                        // the raw _showAverage did.
                        selected: _showAverage && _canOverlay && _rows.length >= 7,
                        onSelected: !_canOverlay || _rows.length < 7
                            ? null
                            : (v) => setState(() => _showAverage = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  ..._interpretation(context, l10n),
                  ..._statsGrid(context, l10n),
                ],
              ),
      ),
    );
  }

  List<Widget> _interpretation(BuildContext context, AppLocalizations l10n) {
    final n = buildPeriodNarrative(_rows, _previous);
    if (n == null) return const [];
    final weekdays = [
      l10n.weekdayMonFull,
      l10n.weekdayTueFull,
      l10n.weekdayWedFull,
      l10n.weekdayThuFull,
      l10n.weekdayFriFull,
      l10n.weekdaySatFull,
      l10n.weekdaySunFull,
    ];
    final sentences = <String>[];
    if (n.bestDayWeekday != null && n.bestDayCount != null) {
      sentences.add(l10n.narrativeBestDay(
          weekdays[n.bestDayWeekday!], n.bestDayCount!));
    }
    final d = n.deltaPercent;
    if (d != null) {
      if (d >= 10) {
        sentences.add(l10n.narrativeUp(d));
      } else if (d <= -10) {
        sentences.add(l10n.narrativeDown(-d));
      } else {
        sentences.add(l10n.narrativeSteady);
      }
    }
    final rd = n.returningDeltaPoints;
    if (rd == null || rd.abs() < 3) {
      sentences.add(l10n.narrativeReturning(n.returningPct));
    } else if (rd > 0) {
      sentences.add(l10n.narrativeReturningUp(n.returningPct, rd));
    } else {
      sentences.add(l10n.narrativeReturningDown(n.returningPct, -rd));
    }
    if (sentences.isEmpty) return const [];

    return [
      Text(l10n.interpretationTitle,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      GlassCard(
        child: Text(sentences.join(' '),
            style:
                Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45)),
      ),
      const SizedBox(height: 24),
    ];
  }

  List<Widget> _statsGrid(BuildContext context, AppLocalizations l10n) {
    if (_rows.isEmpty) return const [];
    final total = sumUnique(_rows);
    final peak = _rows.map((a) => a.unique).fold<int>(0, (m, v) => v > m ? v : m);
    return [
      GlassCard(
        child: ChartStatStrip(stats: [
          (l10n.statAvgDay, '${averagePerDay(total, _rows.length)}'),
          (l10n.statRecord, '$peak'),
          (
            l10n.statReturningPct,
            '${returningRate(sumUnique(_rows), sumReturning(_rows))}%'
          ),
        ]),
      ),
    ];
  }
}

/// The scrubbable trend.
///
/// Two things make this readable that the panel's charts don't do:
///
/// The y-axis is scaled to the data, not to zero. Footfall never drops near
/// zero on a working device, so a zero-based axis spends most of its height
/// on empty space and squashes the variation the operator actually came to
/// look at (490 visitors across four days rendered as a flat line hugging
/// the top). Cropping the axis is only honest if you say where you cropped
/// it, which is why the min and max are printed on the right - the two go
/// together and neither ships without the other.
///
/// Touch drives [onScrub] instead of a tooltip: the parent puts the value in
/// the header, so nothing covers the line under your finger.
class _TrendChart extends StatelessWidget {
  final List<_PlotPoint> points;
  final _Gran gran;
  final List<Aggregate> previous;
  final bool showAverage;

  /// Extra series switched on by the operator.
  final Set<_Series> series;

  /// Closed-hour shading, already resolved to x ranges. Empty when opening
  /// hours are off or the points aren't hours.
  final List<VerticalRangeAnnotation> closedBands;
  final void Function(int?) onScrub;

  const _TrendChart({
    required this.points,
    required this.gran,
    required this.previous,
    required this.showAverage,
    required this.series,
    required this.closedBands,
    required this.onScrub,
  });

  /// Splits into runs of points that are actually adjacent in time.
  ///
  /// A jump in [_PlotPoint.x] means hours the device published nothing for -
  /// under the k-anonymity threshold, or the shop was shut. Drawing one line
  /// through that would invent traffic between two real measurements, so each
  /// run becomes its own line and the gap stays a gap. At daily/weekly
  /// granularity the points are consecutive by construction, so this returns
  /// a single run and costs nothing.
  List<List<_PlotPoint>> _runs() {
    final runs = <List<_PlotPoint>>[];
    var current = <_PlotPoint>[];
    for (final p in points) {
      if (current.isNotEmpty && (p.x - current.last.x).abs() > 1.001) {
        runs.add(current);
        current = [];
      }
      current.add(p);
    }
    if (current.isNotEmpty) runs.add(current);
    return runs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final runs = _runs();

    // Everything drawn decides the window, overlays included - a ghost line
    // running off the top would be worse than a slightly looser axis. The
    // extra series are all subsets of unique, so they can only lower the
    // floor, never raise the ceiling.
    final plotted = <double>[
      ...points.map((p) => p.unique.toDouble()),
      if (series.contains(_Series.returning))
        ...points.map((p) => p.returning.toDouble()),
      if (series.contains(_Series.newVisitors))
        ...points.map((p) => p.newVisitors.toDouble()),
      if (previous.isNotEmpty) ...previous.map((r) => r.unique.toDouble()),
    ];
    var dataMin = plotted.reduce((a, b) => a < b ? a : b);
    var dataMax = plotted.reduce((a, b) => a > b ? a : b);
    // A flat series has no range to scale to; give it air instead of a
    // zero-height window (which fl_chart would render as a divide-by-zero
    // mess).
    final span = dataMax - dataMin;
    final pad = span == 0 ? (dataMax == 0 ? 1.0 : dataMax * 0.2) : span * 0.15;
    final minY = (dataMin - pad).clamp(0.0, double.infinity);
    final maxY = dataMax + pad;

    final bars = <LineChartBarData>[];

    // Ghost first, so the real series draws on top of it.
    if (previous.isNotEmpty) {
      final prev = [...previous]..sort((a, b) => a.date.compareTo(b.date));
      bars.add(LineChartBarData(
        // Plotted against the same x positions: this is "the shape of the
        // period before", laid over today's, not a second calendar axis.
        spots: [
          for (var i = 0; i < prev.length && i < points.length; i++)
            FlSpot(points[i].x, prev[i].unique.toDouble())
        ],
        isCurved: prev.length > 6,
        barWidth: 2,
        color: scheme.outline.withValues(alpha: 0.7),
        dashArray: const [5, 5],
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    // One line per contiguous run, per series. Dots only when the points are
    // sparse enough to read as measurements rather than noise - at hourly
    // granularity there can be a hundred-plus of them.
    final showDots = points.length <= 12;
    // The area fill belongs to a single unbroken series. Filling each run
    // separately turns a broken line into a row of narrow filled columns -
    // it reads as a bar chart of nothing, which is what the hourly view
    // looked like once the overnight gaps split it into seven runs.
    final fillArea = runs.length == 1;
    for (final run in runs) {
      bars.add(revolutLine(
        context,
        [for (final p in run) FlSpot(p.x, p.unique.toDouble())],
        fill: fillArea,
        forceDots: showDots,
      ));
      // Subsets of the visitors line, drawn unfilled so their areas don't
      // muddy the fill underneath (same reasoning as chart_style's two-line
      // helper).
      if (series.contains(_Series.returning)) {
        bars.add(revolutLine(
          context,
          [for (final p in run) FlSpot(p.x, p.returning.toDouble())],
          color: scheme.tertiary,
          fill: false,
          forceDots: showDots,
        ));
      }
      if (series.contains(_Series.newVisitors)) {
        bars.add(revolutLine(
          context,
          [for (final p in run) FlSpot(p.x, p.newVisitors.toDouble())],
          color: scheme.secondary,
          fill: false,
          forceDots: showDots,
        ));
      }
    }

    // Guarded by the same rule the chip uses: under a full window every
    // point is null and this would add an empty, invisible series.
    if (showAverage && gran == _Gran.daily && points.length >= 7) {
      final avg = movingAverage(points.map((p) => p.unique).toList(), 7);
      bars.add(LineChartBarData(
        spots: [
          for (var i = 0; i < avg.length; i++)
            if (avg[i] != null) FlSpot(i.toDouble(), avg[i]!)
        ],
        isCurved: true,
        barWidth: 2,
        color: scheme.tertiary,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    final labelStyle = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: scheme.outline);

    // Which x positions get an axis label. Everything fits while there are a
    // handful of points; past that only the ends and the middle, because 168
    // hourly labels would be a grey smear.
    final labelAt = <int, String>{};
    if (points.length <= 7) {
      for (final p in points) {
        labelAt[p.x.round()] = p.axisLabel;
      }
    } else {
      for (final i in {0, (points.length - 1) ~/ 2, points.length - 1}) {
        labelAt[points[i].x.round()] = points[i].axisLabel;
      }
    }

    // Breathing room on both ends. Without it the first and last points sit
    // exactly on the plot's edges - the line looked cropped on the left while
    // the right had the axis-label column to itself, which read as the chart
    // being shoved sideways.
    // Real timeline extent, not the point count: hourly points skip the hours
    // the device never published, so the last x can be far past the length.
    final xFirst = points.first.x;
    final xLast = points.last.x;
    final xSpan = xLast - xFirst;
    final xPad = xSpan <= 0 ? 0.5 : xSpan * 0.04;

    // The y labels float on top of the plot rather than living in a reserved
    // column beside it. A column only ever eats space on one side, so the
    // line sat flush against the left edge while a wide strip of nothing sat
    // on the right - the chart read as shoved sideways. Overlaid, the plot
    // spans the full width and the only inset is the symmetric xPad below.
    // (Revolut does exactly this: labels at the right edge, chart underneath.)
    return Stack(
      children: [
        Positioned.fill(child: _chart(context, scheme, labelAt, labelStyle,
            bars, minY, maxY, xFirst, xLast, xPad)),
        Positioned(
          top: 0,
          right: 0,
          child: Text('${maxY.round()}', style: labelStyle),
        ),
        Positioned(
          // Clear of the x-axis labels underneath.
          bottom: 30,
          right: 0,
          child: Text('${minY.round()}', style: labelStyle),
        ),
      ],
    );
  }

  Widget _chart(
    BuildContext context,
    ColorScheme scheme,
    Map<int, String> labelAt,
    TextStyle? labelStyle,
    List<LineChartBarData> bars,
    double minY,
    double maxY,
    double xFirst,
    double xLast,
    double xPad,
  ) {
    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: xFirst - xPad,
        maxX: xLast + xPad,
        lineBarsData: bars,
        gridData: revolutGrid,
        borderData: revolutBorder,
        rangeAnnotations:
            RangeAnnotations(verticalRangeAnnotations: closedBands),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(),
          leftTitles: const AxisTitles(),
          // Exactly two labels - the window's floor and ceiling - by asking
          // for an interval as wide as the window itself. That's the whole
          // job: say where the axis was cropped, without turning into a
          // ruler.
          // No reserved column for the y labels - see the Stack in build().
          rightTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                // x is a timeline position, so match by rounding rather than
                // indexing - hourly points skip the hours with no data.
                final key = value.round();
                if ((value - key).abs() > 0.01) return const SizedBox.shrink();
                final label = labelAt[key];
                if (label == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(label, style: labelStyle),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          // The header is the readout, so the tooltip would only duplicate it
          // while hiding the line.
          touchTooltipData: noLineTooltip,
          getTouchedSpotIndicator: (bar, indexes) => [
            for (final _ in indexes)
              TouchedSpotIndicatorData(
                FlLine(color: scheme.primary.withValues(alpha: 0.5), strokeWidth: 1),
                FlDotData(
                  getDotPainter: (s, p, b, i) => FlDotCirclePainter(
                    radius: 5,
                    color: scheme.primary,
                    strokeWidth: 2,
                    strokeColor: scheme.surface,
                  ),
                ),
              ),
          ],
          touchCallback: (event, response) {
            final spot = response?.lineBarSpots?.firstOrNull;
            // Only report while a finger is actually down; releasing hands
            // back null so the header returns to the period summary.
            if (spot == null || event is FlPointerExitEvent ||
                event is FlLongPressEnd || event is FlPanEndEvent ||
                event is FlTapUpEvent) {
              onScrub(null);
              return;
            }
            // Map the touched x back to a point. x is a timeline position,
            // not an index - at hourly granularity the two diverge the moment
            // a single hour is missing.
            final i = points.indexWhere((p) => (p.x - spot.x).abs() < 0.001);
            onScrub(i >= 0 ? i : null);
          },
        ),
      ),
    );
  }
}
