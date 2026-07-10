import 'package:flutter/material.dart';

/// Shared bottom-sheet shell for chart tap-to-detail (Dashboard's
/// hourly/daily charts, Statistics' weekday chart). A raw number with
/// no context ("Pt: 17") isn't useful on its own - every call site
/// supplies a plain-language [interpretation] line (vs. average, peak
/// indicator, etc.) alongside the numbers.
void showDetailSheet(
  BuildContext context, {
  required String title,
  required String primaryValue,
  required String primaryLabel,
  List<(String, String)> rows = const [],
  String? interpretation,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(primaryValue, style: Theme.of(context).textTheme.headlineMedium),
          Text(primaryLabel, style: Theme.of(context).textTheme.bodySmall),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...rows.map(
              (r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r.$1, style: Theme.of(context).textTheme.bodyMedium),
                    Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ],
          if (interpretation != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.insights,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(interpretation,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
