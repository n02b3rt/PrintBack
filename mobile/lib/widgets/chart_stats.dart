import 'package:flutter/material.dart';

/// A compact row of three numbers under a chart.
///
/// The charts here deliberately carry no axes and no value labels - the exact
/// figures live in the tap-to-detail sheet (widgets/chart_style.dart). That
/// keeps them clean, but it also left the cards mostly empty: a title, some
/// floating bars, and a lot of air. This is what goes in that space: the two
/// or three numbers worth reading at a glance, without reintroducing the axis
/// clutter the charts were designed to avoid.
///
/// Each entry is a (label, value) pair; the caller decides what's worth
/// showing for its own chart, since "peak" means something different on an
/// hourly chart than on a daily one.
///
/// Every cell gets an equal share of the row, so keep values short. A value
/// that outgrows its share ellipsises, and it does it from the right - which
/// is where the number usually is. Prefer "Czw · 198" over "Czwartek · 198"
/// rather than relying on the truncation to be graceful; it isn't.
class ChartStatStrip extends StatelessWidget {
  final List<(String label, String value)> stats;

  const ChartStatStrip({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (label, value)) in stats.indexed)
          Expanded(
            child: Padding(
              // A gutter between cells. Without it a value that fills its
              // share butts straight up against the next one and the two read
              // as a single garbled string.
              padding: EdgeInsets.only(right: i == stats.length - 1 ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
