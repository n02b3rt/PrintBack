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
  bool _showPrevious = false;
  bool _showAverage = true;

  List<Aggregate> _rows = [];
  List<Aggregate> _previous = [];
  bool _loading = true;

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
                  Text('$total',
                      style: theme.textTheme.displayMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(l10n.totalUniqueLabel,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                  const SizedBox(height: 4),
                  Text(_deltaSentence(l10n),
                      style: theme.textTheme.bodyMedium),
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
                              locale: l10n.localeName,
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
    final total = sumUnique(_rows);
    final best = bestDay(_rows);
    return [
      GlassCard(
        child: ChartStatStrip(stats: [
          (l10n.statAvgDay, '${averagePerDay(total, _rows.length)}'),
          (l10n.statRecord, best == null ? '-' : '${best.unique}'),
          (
            l10n.statReturningPct,
            '${returningRate(total, sumReturning(_rows))}%'
          ),
        ]),
      ),
    ];
  }
}

/// The scrubbable trend. fl_chart's built-in touch handling gives
/// drag-along-the-line for free (a vertical indicator plus a tooltip that
/// follows the finger), which is the whole point of this screen - so unlike
/// the panel's charts, this one keeps its tooltip instead of pushing exact
/// values into a sheet.
class _TrendChart extends StatelessWidget {
  final List<Aggregate> rows;
  final List<Aggregate> previous;
  final bool showAverage;
  final String locale;

  const _TrendChart({
    required this.rows,
    required this.previous,
    required this.showAverage,
    required this.locale,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spots = [
      for (var i = 0; i < rows.length; i++)
        FlSpot(i.toDouble(), rows[i].unique.toDouble())
    ];

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

    return LineChart(
      LineChartData(
        lineBarsData: bars,
        gridData: revolutGrid,
        borderData: revolutBorder,
        titlesData: revolutTitles(
          context,
          bottomInterval: 1,
          bottomBuilder: (value, meta) {
            final i = value.toInt();
            if (value != i.toDouble() || i < 0 || i >= rows.length) {
              return const SizedBox.shrink();
            }
            if (!showDayLabelAt(i, rows.length)) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(formatAxisDay(rows[i].date),
                  style: Theme.of(context).textTheme.labelSmall),
            );
          },
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final s in spots)
                if (s.barIndex == (previous.isNotEmpty ? 1 : 0))
                  LineTooltipItem(
                    '${formatDayTitle(rows[s.x.toInt()].date, locale)}\n'
                    '${s.y.toInt()}',
                    TextStyle(
                        color: scheme.onSurface, fontWeight: FontWeight.w600),
                  )
                else
                  null,
            ],
          ),
        ),
      ),
    );
  }
}
