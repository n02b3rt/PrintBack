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
  final String title;

  const ChartDetail({super.key, required this.deviceId, required this.title});

  @override
  State<ChartDetail> createState() => _ChartDetailState();
}

class _ChartDetailState extends State<ChartDetail> {
  final _localDb = LocalDb();

  _Range _range = _Range.d30;
  final Set<_Series> _series = {};
  bool _showPrevious = false;
  bool _showAverage = true;

  /// "New" is unique minus returning, clamped - the same definition the KPI
  /// cards use, kept in one place so the two can't drift.
  static int newOf(Aggregate a) => (a.unique - a.returning).clamp(0, a.unique);

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
    final diff = sumUnique(_rows) - sumUnique(_previous);
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
    final scrubbed = (i != null && i >= 0 && i < _rows.length) ? _rows[i] : null;

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
            '${scrubbed == null ? total : scrubbed.unique}',
            style: theme.textTheme.displayMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            l10n.uniqueLabel,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 4),
          if (scrubbed == null)
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
            )
          else
            // Scrubbing: the date, plus whatever extra series are switched on
            // for that same day - otherwise turning "Powracający" on would
            // draw a line whose numbers you could never read.
            Row(
              children: [
                Expanded(
                  child: Text(formatDayTitle(scrubbed.date, l10n.localeName),
                      style: theme.textTheme.bodyMedium),
                ),
                if (_series.contains(_Series.returning))
                  _scrubChip(theme, l10n.returningLabel, scrubbed.returning,
                      theme.colorScheme.tertiary),
                if (_series.contains(_Series.newVisitors))
                  _scrubChip(theme, l10n.newVisitorsLabel, newOf(scrubbed),
                      theme.colorScheme.secondary),
              ],
            ),
        ],
      ),
    );
  }

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
                              series: _series,
                              onScrub: (i) {
                                if (i != _scrub) setState(() => _scrub = i);
                              },
                            ),
                    ),
                  ),
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
  final List<Aggregate> rows;
  final List<Aggregate> previous;
  final bool showAverage;

  /// Extra series switched on by the operator.
  final Set<_Series> series;
  final void Function(int?) onScrub;

  const _TrendChart({
    required this.rows,
    required this.previous,
    required this.showAverage,
    required this.series,
    required this.onScrub,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spots = [
      for (var i = 0; i < rows.length; i++)
        FlSpot(i.toDouble(), rows[i].unique.toDouble())
    ];

    // Everything drawn decides the window, overlays included - a ghost line
    // running off the top would be worse than a slightly looser axis. The
    // extra series are all subsets of unique, so they can only lower the
    // floor, never raise the ceiling.
    final plotted = <double>[
      ...rows.map((r) => r.unique.toDouble()),
      if (series.contains(_Series.returning))
        ...rows.map((r) => r.returning.toDouble()),
      if (series.contains(_Series.newVisitors))
        ...rows.map((r) => _ChartDetailState.newOf(r).toDouble()),
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
          for (var i = 0; i < prev.length && i < rows.length; i++)
            FlSpot(i.toDouble(), prev[i].unique.toDouble())
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

    // Subsets of the visitors line, drawn unfilled so their areas don't
    // muddy the fill underneath (same reasoning as chart_style's two-line
    // helper).
    if (series.contains(_Series.returning)) {
      bars.add(revolutLine(
        context,
        [
          for (var i = 0; i < rows.length; i++)
            FlSpot(i.toDouble(), rows[i].returning.toDouble())
        ],
        color: scheme.tertiary,
        fill: false,
      ));
    }
    if (series.contains(_Series.newVisitors)) {
      bars.add(revolutLine(
        context,
        [
          for (var i = 0; i < rows.length; i++)
            FlSpot(i.toDouble(),
                _ChartDetailState.newOf(rows[i]).toDouble())
        ],
        color: scheme.secondary,
        fill: false,
      ));
    }

    // Guarded by the same rule the chip uses: under a full window every
    // point is null and this would add an empty, invisible series.
    if (showAverage && rows.length >= 7) {
      final avg = movingAverage(rows.map((r) => r.unique).toList(), 7);
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
