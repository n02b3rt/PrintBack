import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/device_illustration.dart';
import '../widgets/gradient_background.dart';

/// One page of a tutorial: a sentence or two, optionally next to the device
/// with its LED doing the exact thing the text is describing.
class TutorialStep {
  final String title;
  final String body;

  /// When set, the drawn device animates this state - the whitelist
  /// walkthrough's whole point is that you can compare the amber blink on
  /// screen with the one in your hand.
  final LedState? led;

  /// A plain icon for steps that aren't about the device itself.
  final IconData? icon;

  const TutorialStep({
    required this.title,
    required this.body,
    this.led,
    this.icon,
  });
}

/// A short, linear, hand-held walkthrough. Deliberately not the coach-mark
/// overlay: coach marks point at what's already on screen, while these
/// explain things that happen on the device or across several screens, which
/// a spotlight can't show.
class TutorialFlow extends StatefulWidget {
  final String title;
  final List<TutorialStep> steps;

  const TutorialFlow({super.key, required this.title, required this.steps});

  @override
  State<TutorialFlow> createState() => _TutorialFlowState();
}

class _TutorialFlowState extends State<TutorialFlow> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index >= widget.steps.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _controller.nextPage(
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isLast = _index >= widget.steps.length - 1;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemCount: widget.steps.length,
                  itemBuilder: (context, i) {
                    final step = widget.steps[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (step.led != null)
                            DeviceIllustration(led: step.led!, size: 190)
                          else if (step.icon != null)
                            Icon(step.icon,
                                size: 84, color: theme.colorScheme.primary),
                          const SizedBox(height: 32),
                          Text(step.title,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          Text(step.body,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(height: 1.5)),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.steps.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 20 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _next,
                    child: Text(isLast ? l10n.tutorialDone : l10n.tutorialNext),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tutorials themselves. Kept next to the flow that renders them so the
/// content and its shape stay together, and so adding one is a list entry
/// rather than a new screen.
List<TutorialStep> whitelistTutorial(AppLocalizations l10n) => [
      TutorialStep(
          title: l10n.wlStep1Title,
          body: l10n.wlStep1Body,
          icon: Icons.groups_outlined),
      // The device blinks amber on screen exactly as it does in the hand.
      TutorialStep(
          title: l10n.wlStep2Title, body: l10n.wlStep2Body, led: LedState.armed),
      TutorialStep(
          title: l10n.wlStep3Title,
          body: l10n.wlStep3Body,
          icon: Icons.phonelink_ring),
      TutorialStep(
          title: l10n.wlStep4Title,
          body: l10n.wlStep4Body,
          icon: Icons.visibility_outlined),
    ];

List<TutorialStep> exportTutorial(AppLocalizations l10n) => [
      TutorialStep(
          title: l10n.exStep1Title,
          body: l10n.exStep1Body,
          icon: Icons.compare_arrows),
      TutorialStep(
          title: l10n.exStep2Title,
          body: l10n.exStep2Body,
          icon: Icons.date_range),
      TutorialStep(
          title: l10n.exStep3Title, body: l10n.exStep3Body, icon: Icons.share),
    ];

List<TutorialStep> firstWeekTutorial(AppLocalizations l10n) => [
      TutorialStep(
          title: l10n.fwStep1Title, body: l10n.fwStep1Body, led: LedState.idle),
      TutorialStep(
          title: l10n.fwStep2Title,
          body: l10n.fwStep2Body,
          icon: Icons.groups_outlined),
      TutorialStep(
          title: l10n.fwStep3Title,
          body: l10n.fwStep3Body,
          icon: Icons.lightbulb_outline),
      TutorialStep(
          title: l10n.fwStep4Title,
          body: l10n.fwStep4Body,
          icon: Icons.notifications_active_outlined),
    ];
