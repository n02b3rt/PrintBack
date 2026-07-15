import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/gradient_background.dart';

/// Plain-language "how it works" FAQ, reachable from Settings. Five
/// questions from the report (3.6) covering where the numbers come from,
/// why it's a trend not an exact count, what the device sees, what is not
/// collected, and what to do when numbers look off - the honesty that
/// builds trust with a non-technical owner, kept in the app not just the
/// README.
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
