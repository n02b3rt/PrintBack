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
LineChartBarData revolutLine(
  BuildContext context,
  List<FlSpot> spots, {
  Color? color,
  bool fill = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  final lineColor = color ?? scheme.primary;
  return LineChartBarData(
    spots: spots,
    isCurved: true,
    curveSmoothness: 0.25,
    barWidth: 3,
    color: lineColor,
    dotData: const FlDotData(show: false),
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

/// Two-series version of revolutLine - "Nowi" (primary, filled) and
/// "Powracający" (tertiary, unfilled so its area doesn't muddy the
/// primary series' fill underneath it). Tertiary rather than secondary:
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
