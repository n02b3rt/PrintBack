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

/// Disable fl_chart's built-in value tooltip. The app shows a
/// tap-to-detail sheet instead, so the default raw-number bubble
/// ("154.0", "0.0") is redundant and reads as a glitch when it pops up
/// under a finger. Touch callbacks still fire; only the bubble is gone.
final noLineTooltip = LineTouchTooltipData(
  getTooltipItems: (spots) => spots.map((_) => null).toList(),
);
final noBarTooltip = BarTouchTooltipData(
  getTooltipItem: (group, groupIndex, rod, rodIndex) => null,
);

/// No axis labels at all, on any side - for charts with too many x
/// values to label without crowding (e.g. 24 hourly bars), where a
/// thinned interval still reads as clutter. The tap-to-detail sheet is
/// the only place a specific value/hour ever gets named.
const revolutTitlesNone = FlTitlesData(show: false);

/// Bottom axis for the 24-bar hourly chart: labels only at 0/6/12/18, so
/// the day has readable anchors (morning/noon/evening) without 24 crammed
/// numbers. A per-x index filter, not fl_chart's `interval`, which
/// doesn't reliably thin a discrete bar axis (docs/LEARNINGS.md hourly
/// x-axis note). x values are the local hour 0-23.
FlTitlesData revolutTitlesSparseHours(BuildContext context) {
  const anchors = {0, 6, 12, 18};
  return FlTitlesData(
    show: true,
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: const AxisTitles(),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        getTitlesWidget: (value, meta) {
          final hour = value.toInt();
          if (!anchors.contains(hour)) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('$hour', style: Theme.of(context).textTheme.bodySmall),
          );
        },
      ),
    ),
  );
}

/// Same visual language as revolutRod, for a line/trend chart instead of
/// bars: a smooth curved gradient stroke with a soft gradient fill below
/// it, no dots (the touch line + detail sheet carry the "exact point"
/// job instead, same as bars never showing a numeric label).
LineChartBarData revolutLine(
  BuildContext context,
  List<FlSpot> spots, {
  Color? color,
  bool fill = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  final lineColor = color ?? scheme.primary;
  // With few points, a smooth curve invents motion between measurements
  // that were never taken - draw a straight polyline and mark the actual
  // data points instead, so early/sparse data reads honestly (10m). Past
  // ~6-10 points the curve reads fine and dots would just be clutter.
  return LineChartBarData(
    spots: spots,
    isCurved: spots.length > 6,
    curveSmoothness: 0.25,
    barWidth: 3,
    color: lineColor,
    dotData: FlDotData(show: spots.length <= 10),
    belowBarData: BarAreaData(
      show: fill,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.35),
          lineColor.withValues(alpha: 0.0),
        ],
      ),
    ),
  );
}

/// Two-series version of revolutLine - "Odwiedzający" (all visitors;
/// primary, filled) and "Powracający" (the returning subset; tertiary,
/// unfilled so its area doesn't muddy the primary series' fill underneath
/// it). The two lines are the visitor total and its returning subset, not
/// "new vs returning" - two overlapping "new/returning" lines would sum to
/// an invisible whole, whereas total + subset reads cleanly (10k).
/// Tertiary rather than secondary:
/// Material 3's seed algorithm makes secondary a desaturated variant of
/// the SAME hue as primary (reads as "duller teal", easy to confuse at a
/// glance), while tertiary is hue-shifted to a genuinely different color
/// - the two lines need to be tellable apart without reading the legend
/// every time. Both fields already exist on every aggregate row and are
/// already shown side by side everywhere else in the app (KPI cards,
/// detail sheet rows) - this is a different view of the same
/// already-aggregated counts, not new data.
List<LineChartBarData> revolutTwoLines(
  BuildContext context, {
  required List<FlSpot> uniqueSpots,
  required List<FlSpot> returningSpots,
}) {
  final scheme = Theme.of(context).colorScheme;
  return [
    revolutLine(context, uniqueSpots, color: scheme.primary),
    revolutLine(context, returningSpots, color: scheme.tertiary, fill: false),
  ];
}

/// Small "● label" legend row, e.g. for a two-line chart where color
/// alone wouldn't otherwise say which line is which.
Widget revolutLegend(BuildContext context, List<(Color, String)> entries) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (color, label) in entries) ...[
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 16),
      ],
    ],
  );
}
