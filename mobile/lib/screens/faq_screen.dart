import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/gradient_background.dart';

/// Plain-language "how it works" FAQ, reachable from Settings - the honesty
/// that builds trust with a non-technical owner, kept in the app and not
/// just in the README.
///
/// The first five cover where the numbers come from, why it's a trend and
/// not an exact count, what the device sees, what isn't collected, and what
/// to do when numbers look off. The rest answer the questions that actually
/// come up once it's running: retention, the "<5" badge, gaps in the hourly
/// chart, power loss, how many phones fit, recovering a broken pairing, the
/// button/LED cheat sheet, MAC randomisation, moving premises, and staff
/// skewing the counts. Every number quoted here is checked against the
/// firmware rather than assumed - e.g. three phones, not eight: the bond
/// store is capped at CONFIG_BT_NIMBLE_MAX_BONDS=3, whatever the size of
/// the whitelist array in ble_gatt.c suggests.
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final qa = [
      (l10n.faqQ1, l10n.faqA1),
      (l10n.faqQ2, l10n.faqA2),
      (l10n.faqQ3, l10n.faqA3),
      (l10n.faqQ4, l10n.faqA4),
      (l10n.faqQ5, l10n.faqA5),
      (l10n.faqQ6, l10n.faqA6),
      (l10n.faqQ7, l10n.faqA7),
      (l10n.faqQ8, l10n.faqA8),
      (l10n.faqQ9, l10n.faqA9),
      (l10n.faqQ10, l10n.faqA10),
      (l10n.faqQ11, l10n.faqA11),
      (l10n.faqQ12, l10n.faqA12),
      (l10n.faqQ13, l10n.faqA13),
      (l10n.faqQ14, l10n.faqA14),
      (l10n.faqQ15, l10n.faqA15),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.howItWorksTitle)),
      body: GradientBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (q, a) in qa)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ExpansionTile(
                  title: Text(q,
                      style: Theme.of(context).textTheme.titleSmall),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
