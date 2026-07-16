import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// One coach mark: the widget to spotlight (via its GlobalKey) and the
/// caption to show next to it.
class CoachTarget {
  final GlobalKey key;
  final String text;
  const CoachTarget(this.key, this.text);
}

/// A dependency-free coach-mark tour: dims the screen, spotlights one
/// target at a time (a real hole cut around the widget's on-screen rect),
/// shows a caption bubble, and advances on tap. "Skip" ends the whole
/// tour. Custom OverlayEntry rather than a package so the look stays
/// consistent with the app's glass style and there's no extra dependency
/// (report 3.5, plan B chosen deliberately).
class CoachMarks {
  /// Shows the tour over the current overlay. Targets whose widget isn't
  /// laid out (no render box) are skipped. [onDone] fires once when the
  /// tour finishes or is skipped - persist the "seen" flag there.
  static void show(
    BuildContext context,
    List<CoachTarget> targets, {
    required VoidCallback onDone,
  }) {
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CoachOverlay(
        targets: targets,
        onFinish: () {
          entry.remove();
          onDone();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _CoachOverlay extends StatefulWidget {
  final List<CoachTarget> targets;
  final VoidCallback onFinish;

  const _CoachOverlay({required this.targets, required this.onFinish});

  @override
  State<_CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<_CoachOverlay> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Even the first target may be below the fold.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(0));
  }

  Rect? _rectFor(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Scrolls [i]'s target into view before spotlighting it.
  ///
  /// Without this the tour cheerfully pointed at things the operator could
  /// not see: the panel is a long scrolling list, so a target below the fold
  /// got a spotlight drawn off-screen (or, in the lazy list, no render box at
  /// all and the step was silently dropped). Telling someone "this is your
  /// hourly chart" while showing them a dimmed screen with a hole somewhere
  /// past the bottom edge is worse than not telling them.
  Future<void> _reveal(int i) async {
    final ctx = widget.targets[i].key.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        alignment: 0.5, // centre it, so the caption has room either side
      );
      // One more frame so localToGlobal reads the settled position rather
      // than where the target was mid-scroll.
      await Future.delayed(const Duration(milliseconds: 60));
    }
    if (mounted) setState(() => _index = i);
  }

  void _next() {
    // Advance to the next target that actually exists in the tree.
    var i = _index + 1;
    while (i < widget.targets.length &&
        widget.targets[i].key.currentContext == null) {
      i++;
    }
    if (i >= widget.targets.length) {
      widget.onFinish();
    } else {
      _reveal(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final target = widget.targets[_index];
    final rect = _rectFor(target.key);
    if (rect == null) {
      // Nothing to point at - end gracefully.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinish());
      return const SizedBox.shrink();
    }

    final size = MediaQuery.of(context).size;
    final spotlight = rect.inflate(8);
    final isLast = _index == widget.targets.length - 1;
    // Put the bubble on the roomier side of the spotlight.
    final below = spotlight.center.dy < size.height / 2;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Dim + spotlight hole; tapping the dim advances.
          Positioned.fill(
            child: GestureDetector(
              onTap: _next,
              child: CustomPaint(
                painter: _SpotlightPainter(spotlight),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            top: below ? spotlight.bottom + 16 : null,
            bottom: below ? null : size.height - spotlight.top + 16,
            // Opaque on purpose, overriding the app's card theme. That theme
            // makes cards 5%-white translucent (the glass look), which works
            // over the page gradient but disappears almost completely here,
            // where the card sits on top of a 0.72-black scrim - the tutorial
            // text was barely legible against its own dimmer.
            child: Card(
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(target.text,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface)),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: widget.onFinish,
                          child: Text(l10n.coachSkip),
                        ),
                        FilledButton(
                          onPressed: _next,
                          child: Text(isLast ? l10n.coachDone : l10n.coachNext),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect spotlight;
  _SpotlightPainter(this.spotlight);

  @override
  void paint(Canvas canvas, Size size) {
    // Fill everything except the rounded spotlight rect (even-odd leaves
    // the inner shape unpainted, so the widget beneath shows through).
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(spotlight, const Radius.circular(12)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.72));
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.spotlight != spotlight;
}
