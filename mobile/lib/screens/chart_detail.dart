import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/narrative.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import '../widgets/chart_stats.dart';
import '../widgets/chart_style.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';

enum _Range { d7, d30, max }

/// Which series the whole screen is about. Switching it re-points the
/// headline, the line, the scrub readout and the stats at once - the numbers
/// on screen always describe the same thing, rather than a chart of one
/// metric sitting under a total of another.
enum _Metric { unique, newVisitors, returning }

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
  final String title;

  const ChartDetail({super.key, required this.deviceId, required this.title});

  @override
  State<ChartDetail> createState() => _ChartDetailState();
}

class _ChartDetailState extends State<ChartDetail> {
  final _localDb = LocalDb();

  _Range _range = _Range.d30;
  _Metric _metric = _Metric.unique;
  bool _showPrevious = false;
  bool _showAverage = true;

  /// "New" is unique minus returning, clamped - the same definition the KPI
  /// cards use, kept in one place so the two can't drift.
  int _valueOf(Aggregate a) => switch (_metric) {
        _Metric.unique => a.unique,
        _Metric.returning => a.returning,
        _Metric.newVisitors => (a.unique - a.returning).clamp(0, a.unique),
      };

  int _sumOf(List<Aggregate> rows) =>
      rows.fold<int>(0, (s, a) => s + _valueOf(a));

  String _metricLabel(AppLocalizations l10n) => switch (_metric) {
        _Metric.unique => l10n.uniqueLabel,
        _Metric.returning => l10n.returningLabel,
        _Metric.newVisitors => l10n.newVisitorsLabel,
      };

  List<Aggregate> _rows = [];
  List<Aggregate> _previous = [];
  bool _loading = true;

  /// Which point the finger is on, or null when nobody's touching the chart.
  /// Dragging rewrites the header instead of popping a tooltip over the line:
  /// the number is already the biggest thing on the screen, so putting the
  /// scrubbed value there means the eye never leaves it, and nothing covers
  /// the chart you're reading.
  int? _scrub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int? get _rangeDays => switch (_range) {
        _Range.d7 => 7,
        _Range.d30 => 30,
        _Range.max => null,
      };

  Future<void> _load() async {
    setState(() => _loading = true);
    final days = _rangeDays;

    // "MAX" means the whole cache, which also means there is no earlier
    // period left to compare it against - the ghost overlay is meaningless
    // there and the delta line says so rather than inventing a baseline.
    final rows = await _localDb.recentDaily(widget.deviceId, limit: days);
    List<Aggregate> previous = const [];
    if (days != null) {
      final now = DateTime.now();
      final prevEnd = now.subtract(Duration(days: days));
      final prevStart = prevEnd.subtract(Duration(days: days - 1));
      previous = await _localDb.dailyInRange(
          widget.deviceId, _fmt(prevStart), _fmt(prevEnd));
    }
    if (!mounted) return;
    setState(() {
      // recentDaily comes back newest-first; a trend reads left-to-right.
      _rows = rows.reversed.toList();
      _previous = previous;
      _loading = false;
      _scrub = null; // the old index means nothing against new rows
    });
  }

  static String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// "o 41 więcej niż poprzednie 30 dni" - a count, not a percentage. A shop
  /// owner can picture 41 people; "+18%" is a number about a number.
  String _deltaSentence(AppLocalizations l10n) {
    final days = _rangeDays;
    if (days == null || _previous.isEmpty) return l10n.deltaNoBaseline;
    final diff = _sumOf(_rows) - _sumOf(_previous);
    if (diff == 0) return l10n.deltaSame(days);
    return diff > 0 ? l10n.deltaMore(diff, days) : l10n.deltaFewer(-diff, days);
  }

  /// The period summary, or - while a finger is on the chart - that day.
  ///
  /// Fixed height so the layout doesn't jump between the two states while
  /// scrubbing, which would make the chart shift under the finger.
  Widget _header(BuildContext context, AppLocalizations l10n, int total) {
    final theme = Theme.of(context);
    final i = _scrub;
    final scrubbed = (i != null && i >= 0 && i < _rows.length) ? _rows[i] : null;

    // A floor, not a fixed height: the two states must not make the layout
    // jump (the chart would shift under a scrubbing finger), but a hard
    // SizedBox silently clipped the number when the delta sentence wrapped
    // to two lines. Reserve the taller state's height and let it grow.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 116),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${scrubbed == null ? total : _valueOf(scrubbed)}',
            style: theme.textTheme.displayMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            _metricLabel(l10n),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 4),
          Text(
            scrubbed == null
                ? _deltaSentence(l10n)
                : formatDayTitle(scrubbed.date, l10n.localeName),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final total = _sumOf(_rows);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: GradientBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _header(context, l10n, total),
                  const SizedBox(height: 16),
                  SegmentedButton<_Metric>(
                    segments: [
                      ButtonSegment(
                          value: _Metric.unique, label: Text(l10n.uniqueLabel)),
                      ButtonSegment(
                          value: _Metric.newVisitors,
                          label: Text(l10n.newVisitorsLabel)),
                      ButtonSegment(
                          value: _Metric.returning,
                          label: Text(l10n.returningLabel)),
                    ],
                    selected: {_metric},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() {
                      _metric = s.first;
                      _scrub = null; // stale readout for the new series
                    }),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_Range>(
                    segments: [
                      ButtonSegment(value: _Range.d7, label: Text(l10n.range7d)),
                      ButtonSegment(
                          value: _Range.d30, label: Text(l10n.range30d)),
                      ButtonSegment(
                          value: _Range.max, label: Text(l10n.rangeMax)),
                    ],
                    selected: {_range},
                    onSelectionChanged: (s) {
                      setState(() => _range = s.first);
                      _load();
                    },
                  ),
                  const SizedBox(height: 16),
                  GlassCard(
                    child: SizedBox(
                      height: 240,
                      child: _rows.isEmpty
                          ? Center(child: Text(l10n.emptyNoData))
                          : _TrendChart(
                              rows: _rows,
                              previous: _showPrevious ? _previous : const [],
                              showAverage: _showAverage,
                              value: _valueOf,
                              onScrub: (i) {
                                if (i != _scrub) setState(() => _scrub = i);
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: Text(l10n.overlayPrevious),
                        selected: _showPrevious,
                        // Nothing to ghost against on MAX.
                        onSelected: _previous.isEmpty
                            ? null
                            : (v) => setState(() => _showPrevious = v),
                      ),
                      FilterChip(
                        label: Text(l10n.overlayMovingAvg),
                        // A 7-day average of under 7 days is not one, so the
                        // overlay is unavailable then - and must not read as
                        // ticked while drawing nothing, which is what showing
                        // the raw _showAverage did.
                        selected: _showAverage && _rows.length >= 7,
                        onSelected: _rows.length < 7
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
    final total = _sumOf(_rows);
    // The record is the best day *of the selected metric* - the busiest day
    // for returning visitors isn't necessarily the busiest day overall.
    final peak = _rows.map(_valueOf).fold<int>(0, (m, v) => v > m ? v : m);
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
  final List<Aggregate> rows;
  final List<Aggregate> previous;
  final bool showAverage;

  /// Which number to plot out of each row - the screen's selected metric.
  final int Function(Aggregate) value;
  final void Function(int?) onScrub;

  const _TrendChart({
    required this.rows,
    required this.previous,
    required this.showAverage,
    required this.value,
    required this.onScrub,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spots = [
      for (var i = 0; i < rows.length; i++)
        FlSpot(i.toDouble(), value(rows[i]).toDouble())
    ];

    // Everything drawn decides the window, overlays included - a ghost line
    // running off the top would be worse than a slightly looser axis.
    final plotted = <double>[
      ...rows.map((r) => value(r).toDouble()),
      if (previous.isNotEmpty) ...previous.map((r) => value(r).toDouble()),
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
          for (var i = 0; i < prev.length && i < rows.length; i++)
            FlSpot(i.toDouble(), value(prev[i]).toDouble())
        ],
        isCurved: prev.length > 6,
        barWidth: 2,
        color: scheme.outline.withValues(alpha: 0.7),
        dashArray: const [5, 5],
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    bars.add(revolutLine(context, spots));

    // Guarded by the same rule the chip uses: under a full window every
    // point is null and this would add an empty, invisible series.
    if (showAverage && rows.length >= 7) {
      final avg = movingAverage(rows.map(value).toList(), 7);
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

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        lineBarsData: bars,
        gridData: revolutGrid,
        borderData: revolutBorder,
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(),
          leftTitles: const AxisTitles(),
          // Exactly two labels - the window's floor and ceiling - by asking
          // for an interval as wide as the window itself. That's the whole
          // job: say where the axis was cropped, without turning into a
          // ruler.
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              interval: (maxY - minY).abs() < 0.001 ? 1 : maxY - minY,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('${value.round()}', style: labelStyle),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (value != i.toDouble() || i < 0 || i >= rows.length) {
                  return const SizedBox.shrink();
                }
                if (!showDayLabelAt(i, rows.length)) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(formatAxisDay(rows[i].date), style: labelStyle),
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
            onScrub(spot.x.toInt());
          },
        ),
      ),
    );
  }
}
