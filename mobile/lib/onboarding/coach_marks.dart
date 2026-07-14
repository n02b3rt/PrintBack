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

  Rect? _rectFor(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _next() {
    // Advance to the next target that actually has an on-screen rect.
    var i = _index + 1;
    while (i < widget.targets.length && _rectFor(widget.targets[i].key) == null) {
      i++;
    }
    if (i >= widget.targets.length) {
      widget.onFinish();
    } else {
      setState(() => _index = i);
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
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(target.text,
                        style: Theme.of(context).textTheme.bodyLarge),
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
