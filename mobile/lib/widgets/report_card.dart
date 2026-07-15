import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The shareable footfall summary card - a self-contained visual (brand,
/// period, the three KPIs) captured to an image and shared via the OS
/// sheet (report 4, "export"). Fixed dark styling so the exported picture
/// looks the same regardless of the sender's or recipient's theme; only
/// already-aggregated counts, never per-client data.
class ReportCard extends StatelessWidget {
  final String periodLabel;
  final String dateRange;
  final int unique;
  final int newVisitors;
  final int returning;

  const ReportCard({
    super.key,
    required this.periodLabel,
    required this.dateRange,
    required this.unique,
    required this.newVisitors,
    required this.returning,
  });

  static const _bg = Color(0xFF10201D);
  static const _accent = Color(0xFF54D0BA);
  static const _muted = Color(0xFF9BB3AD);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: 360,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                    color: _accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text('PrintBack',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 20),
          Text(periodLabel,
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(dateRange, style: const TextStyle(color: _muted, fontSize: 14)),
          const SizedBox(height: 24),
          Row(
            children: [
              _kpi(l10n.uniqueLabel, unique),
              const SizedBox(width: 12),
              _kpi(l10n.newVisitorsLabel, newVisitors),
              const SizedBox(width: 12),
              _kpi(l10n.returningLabel, returning),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kpi(String label, int value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$value',
                style: const TextStyle(
                    color: _accent, fontSize: 26, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(color: _muted, fontSize: 12),
                maxLines: 2),
          ],
        ),
      ),
    );
  }
}
