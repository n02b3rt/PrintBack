import 'package:flutter/material.dart';

/// Which LED animation the on-screen device is showing. Mirrors the
/// firmware's own UI states so the onboarding wizard can render a device
/// whose light behaves exactly like the real one in the user's hand.
enum LedState { off, boot, idle, pairing, syncing }

/// A drawn PrintBack device (rounded body + button + RGB LED) whose LED
/// animates in lock-step with the real firmware. The colour/timing for
/// each [LedState] is a 1:1 port of `render()` in firmware/main/ui.c - if
/// the firmware ever changes a timing, update it there and here together
/// (there's no shared source between C and Dart for this).
class DeviceIllustration extends StatefulWidget {
  final LedState led;
  final double size;

  const DeviceIllustration({super.key, required this.led, this.size = 180});

  @override
  State<DeviceIllustration> createState() => _DeviceIllustrationState();
}

class _DeviceIllustrationState extends State<DeviceIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // A free-running ticker; lastElapsedDuration is a monotonic clock we
    // read in the painter (it does not reset between repeats), so each
    // state derives its own cycle from it with a plain modulo.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final ms = _controller.lastElapsedDuration?.inMilliseconds ?? 0;
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _DevicePainter(
            led: _ledColor(widget.led, ms),
            bodyColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            outlineColor: Theme.of(context).colorScheme.outlineVariant,
          ),
        );
      },
    );
  }

  // --- ports of firmware/main/ui.c render(), colours in device space ---

  static const _off = Color(0xFF141414);

  Color _ledColor(LedState state, int ms) {
    switch (state) {
      case LedState.off:
        return _off;
      case LedState.boot:
        // R->G->B->white, 500ms each, then a short dark pause before it
        // loops (matches the physical self-test on power-on).
        final t = ms % 2600;
        if (t < 500) return const Color(0xFFFF0000);
        if (t < 1000) return const Color(0xFF00FF00);
        if (t < 1500) return const Color(0xFF0000FF);
        if (t < 2000) return const Color(0xFFC8C8C8);
        return _off;
      case LedState.pairing:
        // Cyan blink ~2Hz (250ms on/off).
        return (ms ~/ 250) % 2 == 1 ? const Color(0xFF00C8C8) : _off;
      case LedState.syncing:
        // Breathing blue, 1200ms triangle, never fully off (20..220).
        final t = ms % 1200;
        final up = t < 600 ? t : 1200 - t;
        final v = 20 + up * 200 ~/ 600;
        return Color.fromARGB(255, 0, 0, v);
      case LedState.idle:
        // Dim white triangular pulse ~0.5Hz (host-connected idle).
        final t = ms % 2000;
        final up = t < 1000 ? t : 2000 - t;
        final v = up * 60 ~/ 1000;
        return Color.fromARGB(255, v, v, v);
    }
  }
}

class _DevicePainter extends CustomPainter {
  final Color led;
  final Color bodyColor;
  final Color outlineColor;

  _DevicePainter({
    required this.led,
    required this.bodyColor,
    required this.outlineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Device body: a rounded rectangle roughly a dev-board footprint.
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.22, h * 0.18, w * 0.56, h * 0.64),
      Radius.circular(w * 0.06),
    );
    canvas.drawRRect(body, Paint()..color = bodyColor);
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.012
        ..color = outlineColor,
    );

    // USB stub at the top edge (hints "plug it into power").
    final usb = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.42, h * 0.10, w * 0.16, h * 0.09),
      Radius.circular(w * 0.015),
    );
    canvas.drawRRect(usb, Paint()..color = outlineColor);

    // Button.
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.66),
      w * 0.05,
      Paint()..color = outlineColor,
    );

    // LED: a glow halo then the lit core, so bright states read as "lit"
    // not just "a coloured dot".
    final ledCenter = Offset(w * 0.5, h * 0.40);
    canvas.drawCircle(
      ledCenter,
      w * 0.13,
      Paint()
        ..color = led.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawCircle(ledCenter, w * 0.055, Paint()..color = led);
  }

  @override
  bool shouldRepaint(_DevicePainter old) =>
      old.led != led || old.bodyColor != bodyColor;
}
