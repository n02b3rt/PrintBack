import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Shared bar look across all charts in the app - rounded tops, a soft
/// vertical gradient fill, no grid lines or axis border. Closer to how
/// Revolut/Robinhood-style finance apps render bars (the bar itself
/// carries the visual weight, exact numbers live in the tap-to-detail
/// sheet, not in axis clutter) than fl_chart's flat-color defaults.
BarChartRodData revolutRod(
  BuildContext context,
  double value, {
  bool highlight = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final top = highlight ? scheme.primary : scheme.primary.withValues(alpha: 0.55);
  final bottom = highlight
      ? scheme.primary.withValues(alpha: 0.65)
      : scheme.primary.withValues(alpha: 0.15);
  return BarChartRodData(
    toY: value,
    width: 14,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [top, bottom],
    ),
  );
}

/// No y-axis at all (exact values live in the tap-to-detail sheet, not
/// axis clutter), a light bottom axis for date/hour/day labels, no grid
/// lines, no chart border - the minimal look bar #2 above describes.
FlTitlesData revolutTitles(
  BuildContext context, {
  required Widget Function(double, TitleMeta) bottomBuilder,
  double? bottomInterval,
}) {
  return FlTitlesData(
    show: true,
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: const AxisTitles(),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: bottomInterval,
        getTitlesWidget: bottomBuilder,
      ),
    ),
  );
}

const revolutGrid = FlGridData(show: false);
final revolutBorder = FlBorderData(show: false);

/// No axis labels at all, on any side - for charts with too many x
/// values to label without crowding (e.g. 24 hourly bars), where a
/// thinned interval still reads as clutter. The tap-to-detail sheet is
/// the only place a specific value/hour ever gets named.
const revolutTitlesNone = FlTitlesData(show: false);

/// Same visual language as revolutRod, for a line/trend chart instead of
/// bars: a smooth curved gradient stroke with a soft gradient fill below
/// it, no dots (the touch line + detail sheet carry the "exact point"
/// job instead, same as bars never showing a numeric label).
LineChartBarData revolutLine(BuildContext context, List<FlSpot> spots) {
  final scheme = Theme.of(context).colorScheme;
  return LineChartBarData(
    spots: spots,
    isCurved: true,
    curveSmoothness: 0.25,
    barWidth: 3,
    color: scheme.primary,
    dotData: const FlDotData(show: false),
    belowBarData: BarAreaData(
      show: true,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          scheme.primary.withValues(alpha: 0.35),
          scheme.primary.withValues(alpha: 0.0),
        ],
      ),
    ),
  );
}
