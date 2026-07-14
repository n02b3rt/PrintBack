import 'package:flutter/material.dart';

import '../screens/connecting_screen.dart';
import '../widgets/gradient_background.dart';
import 'onboarding_flags.dart';
import 'welcome_carousel.dart';

/// App entry point that decides, once per launch, whether to run the
/// first-run onboarding (welcome carousel) or go straight to the normal
/// connect flow. A tiny FutureBuilder on the persisted `onboarding_done`
/// flag - blank gradient while the (near-instant) prefs read resolves.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: OnboardingFlags.onboardingDone(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: GradientBackground(child: SizedBox()));
        }
        return snapshot.data!
            ? const ConnectingScreen()
            : const WelcomeCarousel();
      },
    );
  }
}
