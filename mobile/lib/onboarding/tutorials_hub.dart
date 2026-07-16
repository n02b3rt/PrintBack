import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import 'tutorial_flow.dart';

/// One place listing every walkthrough, so "show me how this works" has an
/// answer that isn't "read the FAQ and infer it". The FAQ answers questions;
/// these walk the operator through a task.
class TutorialsHub extends StatelessWidget {
  const TutorialsHub({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = <(IconData, String, String, List<TutorialStep>)>[
      (
        Icons.calendar_month_outlined,
        l10n.tutorialFirstWeekTitle,
        l10n.tutorialFirstWeekSubtitle,
        firstWeekTutorial(l10n),
      ),
      (
        Icons.groups_outlined,
        l10n.tutorialWhitelistTitle,
        l10n.tutorialWhitelistSubtitle,
        whitelistTutorial(l10n),
      ),
      (
        Icons.ios_share,
        l10n.tutorialExportTitle,
        l10n.tutorialExportSubtitle,
        exportTutorial(l10n),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.tutorialsTitle)),
      body: GradientBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l10n.tutorialsSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      leading: Icon(entries[i].$1),
                      title: Text(entries[i].$2),
                      subtitle: Text(entries[i].$3),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TutorialFlow(
                              title: entries[i].$2, steps: entries[i].$4),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
