import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../widgets/gradient_background.dart';
import '../widgets/report_card.dart';

/// Previews the shareable report card and, on demand, rasterizes it to a
/// PNG and hands it to the OS share sheet. The card is on-screen (so the
/// RepaintBoundary is really painted) and captured at high pixel ratio.
class ReportPreview extends StatefulWidget {
  final String periodLabel;
  final String dateRange;
  final int unique;
  final int newVisitors;
  final int returning;

  const ReportPreview({
    super.key,
    required this.periodLabel,
    required this.dateRange,
    required this.unique,
    required this.newVisitors,
    required this.returning,
  });

  @override
  State<ReportPreview> createState() => _ReportPreviewState();
}

class _ReportPreviewState extends State<ReportPreview> {
  final _boundaryKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary = _boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      // Directory.systemTemp is the app cache dir on Android - shareable,
      // no path_provider dependency needed.
      final file = File('${Directory.systemTemp.path}/printback_report.png');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: AppLocalizations.of(context)!.reportShareText,
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.reportPreviewTitle)),
      body: GradientBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                key: _boundaryKey,
                child: ReportCard(
                  periodLabel: widget.periodLabel,
                  dateRange: widget.dateRange,
                  unique: widget.unique,
                  newVisitors: widget.newVisitors,
                  returning: widget.returning,
                ),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _sharing ? null : _share,
                icon: _sharing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.share),
                label: Text(l10n.shareButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
