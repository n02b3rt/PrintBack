import 'dart:ui';

import 'package:flutter/material.dart';

/// Card with a real backdrop blur in dark mode, matching the approved
/// glass-UI direction - falls back to a plain flat Card in light mode,
/// where a blurred translucent panel reads as washed-out rather than
/// "glass". Used for a handful of cards per screen, not inside a
/// fast-scrolling list, so the blur cost stays negligible.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) {
      return Card(child: Padding(padding: padding, child: child));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          // ListTile/InkWell/etc. paint their background and ink splashes
          // on the nearest Material ancestor - without this, they render
          // invisibly (Flutter throws a framework assertion for it) since
          // the Container above isn't a Material. `transparency` means it
          // contributes no paint of its own, just the ancestor those
          // widgets need - the actual glass color comes from the
          // Container's decoration.
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
