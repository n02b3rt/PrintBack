import 'package:flutter/material.dart';

/// Small dot-with-ring mark used instead of a generic icon-in-a-box
/// logo (explicitly rejected during design review as looking like a
/// generated template rather than a real product mark). The ring
/// reads as "live signal" - fitting for a BLE-connected device app.
class BrandMark extends StatelessWidget {
  final String label;

  const BrandMark({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            border: Border.all(
              color: accent.withValues(alpha: 0.35),
              width: 4,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
