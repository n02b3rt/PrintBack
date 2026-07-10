import 'package:flutter/material.dart';

/// Subtle radial teal glow over the near-black dark theme background,
/// matching the approved glass-UI mockup direction. No-op in light
/// mode, where the flat `scaffoldBackgroundColor` already applies.
/// Wrap a screen's `Scaffold.body` in this, not the whole `Scaffold` -
/// the app bar keeps its own themed background.
class GradientBackground extends StatelessWidget {
  final Widget child;

  const GradientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) return child;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.9),
          radius: 1.1,
          colors: [Color(0x330D9488), Color(0x000A0D0D)],
        ),
      ),
      child: child,
    );
  }
}
