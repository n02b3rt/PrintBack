import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import '../widgets/chart_stats.dart';
import '../widgets/chart_style.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';

/// "How are my Tuesdays going?" - one weekday's history over time.
///
/// The weekday-pattern chart on Statistics answers which day is busiest by
/// averaging every Tuesday into one bar; that average is exactly what hides
/// whether Tuesdays are climbing or sliding. This is the drill-down for a
/// bar of that chart: the same weekday, un-averaged, in date order.
///
/// Reads the cache, so it works offline like every other screen here. The
/// install day is excluded - a half day would show up as a crash in the
/// trend that never happened (lib/logic/stats_math.dart withoutInstallDay).
class WeekdayTrend extends StatefulWidget {
  final String deviceId;

  /// 0 = Monday.
  final int weekday;

  /// Already-localized name, used for the title.
  final String weekdayName;

  const WeekdayTrend({
    super.key,
    required this.deviceId,
    required this.weekday,
    required this.weekdayName,
  });

  @override
  State<WeekdayTrend> createState() => _WeekdayTrendState();
}

class _WeekdayTrendState extends State<WeekdayTrend> {
  final _localDb = LocalDb();
  List<Aggregate> _rows = [];
  bool _loading = true;
  int? _scrub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // No limit: the whole point is the long view, and one weekday is a
    // seventh of the history even at full stretch.
    final all = await _localDb.recentDaily(widget.deviceId);
    final installDate = await _localDb.oldestDailyDate(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _rows = onlyWeekday(withoutInstallDay(all, installDate), widget.weekday);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final title = l10n.weekdayTrendTitle(widget.weekdayName);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // One point is not a trend, and two barely is - say so instead of drawing
    // a line between two dots and calling it a direction.
    if (_rows.length < 2) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: GradientBackground(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(l10n.weekdayTrendEmpty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge),
            ),
          ),
        ),
      );
    }

    final i = _scrub;
    final scrubbed = (i != null && i >= 0 && i < _rows.length) ? _rows[i] : null;
    final total = sumUnique(_rows);
    final latest = _rows.last.unique;
    final avg = averagePerDay(total, _rows.length);
    final best = _rows.map((a) => a.unique).reduce((a, b) => a > b ? a : b);

    // The latest one against the average of the rest: "is this Tuesday
    // better than my Tuesdays usually are".
    final earlier = _rows.sublist(0, _rows.length - 1);
    final vsUsual = earlier.isEmpty
        ? null
        : deltaPercent(latest, averagePerDay(sumUnique(earlier), earlier.length));

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: GradientBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${scrubbed?.unique ?? latest}',
                style: theme.textTheme.displayMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text(l10n.uniqueLabel,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 4),
            Text(
              scrubbed != null
                  ? formatDayTitle(scrubbed.date, l10n.localeName)
                  : (vsUsual == null
                      ? formatDayTitle(_rows.last.date, l10n.localeName)
                      : (vsUsual >= 0
                          ? l10n.narrativeUp(vsUsual)
                          : l10n.narrativeDown(-vsUsual))),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: SizedBox(
                height: 220,
                child: _Chart(
                  rows: _rows,
                  onScrub: (v) {
                    if (v != _scrub) setState(() => _scrub = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: ChartStatStrip(stats: [
                (l10n.statAvgDay, '$avg'),
                (l10n.statRecord, '$best'),
                (l10n.statSum, '$total'),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chart extends StatelessWidget {
  final List<Aggregate> rows;
  final void Function(int?) onScrub;

  const _Chart({required this.rows, required this.onScrub});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.outline);

    final values = rows.map((r) => r.unique.toDouble()).toList();
    final dataMin = values.reduce((a, b) => a < b ? a : b);
    final dataMax = values.reduce((a, b) => a > b ? a : b);
    final span = dataMax - dataMin;
    final pad = span == 0 ? (dataMax == 0 ? 1.0 : dataMax * 0.2) : span * 0.15;
    final minY = (dataMin - pad).clamp(0.0, double.infinity);
    final maxY = dataMax + pad;

    final xSpan = (rows.length - 1).toDouble();
    final xPad = xSpan <= 0 ? 0.5 : xSpan * 0.06;

    // Same treatment as the daily drill-down: full-width plot, y range
    // overlaid in the corners rather than in a column that would only eat
    // space on one side.
    return Stack(
      children: [
        Positioned.fill(
          child: LineChart(
            LineChartData(
              minY: minY,
              maxY: maxY,
              minX: -xPad,
              maxX: xSpan + xPad,
              gridData: revolutGrid,
              borderData: revolutBorder,
              lineBarsData: [
                revolutLine(context, [
                  for (var i = 0; i < rows.length; i++)
                    FlSpot(i.toDouble(), values[i])
                ]),
              ],
              titlesData: FlTitlesData(
                show: true,
                topTitles: const AxisTitles(),
                leftTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
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
                        child:
                            Text(formatAxisDay(rows[i].date), style: labelStyle),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: noLineTooltip,
                getTouchedSpotIndicator: (bar, indexes) => [
                  for (final _ in indexes)
                    TouchedSpotIndicatorData(
                      FlLine(
                          color: scheme.primary.withValues(alpha: 0.5),
                          strokeWidth: 1),
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
                  if (spot == null ||
                      event is FlPointerExitEvent ||
                      event is FlLongPressEnd ||
                      event is FlPanEndEvent ||
                      event is FlTapUpEvent) {
                    onScrub(null);
                    return;
                  }
                  onScrub(spot.x.round());
                },
              ),
            ),
          ),
        ),
        Positioned(
            top: 0, right: 0, child: Text('${maxY.round()}', style: labelStyle)),
        Positioned(
            bottom: 30,
            right: 0,
            child: Text('${minY.round()}', style: labelStyle)),
      ],
    );
  }
}
