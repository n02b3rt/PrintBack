import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/connecting_screen.dart';
import '../widgets/device_illustration.dart';
import '../widgets/gradient_background.dart';
import 'onboarding_flags.dart';

/// First-run intro: three full-screen cards (what it does / how it works /
/// privacy) with progress dots and a skip. Copy is straight from the
/// report's onboarding section - the honesty of card 2 ("a picture of
/// trends, not a person-by-person counter") is deliberate: it sets correct
/// expectations up front and builds trust with a non-technical owner.
class WelcomeCarousel extends StatefulWidget {
  const WelcomeCarousel({super.key});

  @override
  State<WelcomeCarousel> createState() => _WelcomeCarouselState();
}

class _WelcomeCarouselState extends State<WelcomeCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await OnboardingFlags.setOnboardingDone();
    if (!mounted) return;
    // 11a routes both the CTA and the "already paired" link here. In 11c
    // the CTA is rewired to push the guided pairing wizard instead (which
    // sets the done flag on completion); the link keeps going straight to
    // the normal connect flow.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectingScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cards = [
      _CardData(icon: Icons.storefront, title: l10n.welcomeCard1Title, body: l10n.welcomeCard1Body),
      // Card 2 shows the actual drawn device with a live LED, so "how it
      // works" isn't abstract - it's the thing they'll hold.
      _CardData(
        illustration: const DeviceIllustration(led: LedState.idle, size: 150),
        title: l10n.welcomeCard2Title,
        body: l10n.welcomeCard2Body,
      ),
      _CardData(icon: Icons.lock_outline, title: l10n.welcomeCard3Title, body: l10n.welcomeCard3Body),
    ];
    final isLast = _page == cards.length - 1;

    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _finish,
                  child: Text(l10n.onboardingSkip),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: cards.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) => _WelcomeCard(data: cards[i]),
                ),
              ),
              _Dots(count: cards.length, active: _page),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: isLast
                            ? _finish
                            : () => _controller.nextPage(
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                ),
                        child: Text(isLast
                            ? l10n.welcomeConnectCta
                            : MaterialLocalizations.of(context)
                                .continueButtonLabel),
                      ),
                    ),
                    if (isLast)
                      TextButton(
                        onPressed: _finish,
                        child: Text(l10n.welcomeAlreadyPaired),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardData {
  final IconData? icon;
  final Widget? illustration;
  final String title;
  final String body;
  const _CardData({
    this.icon,
    this.illustration,
    required this.title,
    required this.body,
  });
}

class _WelcomeCard extends StatelessWidget {
  final _CardData data;
  const _WelcomeCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // v1 illustration: either the drawn device (card 2) or a simple
          // icon composition (final artwork is a later, non-blocking
          // commit - report Risk 4).
          if (data.illustration != null)
            SizedBox(height: 150, child: data.illustration)
          else
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(data.icon, size: 68, color: scheme.primary),
            ),
          const SizedBox(height: 40),
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            data.body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int active;
  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == active ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == active
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
