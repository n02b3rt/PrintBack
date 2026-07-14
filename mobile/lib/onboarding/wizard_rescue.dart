import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Shown when the wizard's auto-scan times out: a short, plain-language
/// checklist of the usual culprits plus a retry. After a second failure it
/// adds the power-cycle step - which really does recover a wedged board
/// (docs/LEARNINGS.md 2026-07-12), so it's worth surfacing rather than
/// leaving the user stuck.
class WizardRescue extends StatelessWidget {
  final int attempts;
  final VoidCallback onRetry;

  const WizardRescue({super.key, required this.attempts, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final checks = [
      l10n.wizardRescueCheck1,
      l10n.wizardRescueCheck2,
      l10n.wizardRescueCheck3,
      if (attempts >= 2) l10n.wizardRescueCheck4,
    ];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.search_off,
              size: 64, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text(
            l10n.wizardRescueTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          for (final c in checks)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: 10),
                    child: Icon(Icons.chevron_right, size: 20),
                  ),
                  Expanded(
                    child: Text(c,
                        style: Theme.of(context).textTheme.bodyLarge),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onRetry,
            child: Text(l10n.wizardRescueRetry),
          ),
        ],
      ),
    );
  }
}
