import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../services/bug_report.dart';

/// The consent sheet a 3x shake opens (`services/shake_detector.dart`).
///
/// The gesture only ever *opens* this - collection happens when the sheet
/// builds the preview, and submission only on an explicit "Send". The
/// operator can read the exact outgoing text first, and switch the logs off
/// entirely, so consent is informed rather than implied.
Future<void> showBugReportSheet(BuildContext context,
    {BugReportSink sink = const ShareBugReportSink()}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _BugReportBody(sink: sink),
    ),
  );
}

class _BugReportBody extends StatefulWidget {
  final BugReportSink sink;
  const _BugReportBody({required this.sink});

  @override
  State<_BugReportBody> createState() => _BugReportBodyState();
}

class _BugReportBodyState extends State<_BugReportBody> {
  final _controller = TextEditingController();
  bool _includeLogs = true;
  bool _sending = false;
  String? _preview;
  bool _previewOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<BugReport> _build() => buildBugReport(
        ble: context.read<BleService>(),
        description: _controller.text,
        includeLogs: _includeLogs,
      );

  Future<void> _togglePreview() async {
    if (_previewOpen) {
      setState(() => _previewOpen = false);
      return;
    }
    final report = await _build();
    if (!mounted) return;
    setState(() {
      _preview = report.toText();
      _previewOpen = true;
    });
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final report = await _build();
      await widget.sink.submit(report);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bug_report_outlined,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(l10n.bugReportTitle,
                        style: theme.textTheme.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(l10n.bugReportIntro, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                minLines: 3,
                maxLines: 5,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.bugReportWhatHappened,
                  hintText: l10n.bugReportHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeLogs,
                onChanged: (v) => setState(() {
                  _includeLogs = v;
                  _previewOpen = false; // preview must match the new choice
                }),
                title: Text(l10n.bugReportIncludeLogs),
                subtitle: Text(l10n.bugReportIncludeLogsHint,
                    style: theme.textTheme.bodySmall),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 18, color: theme.colorScheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l10n.bugReportPrivacy,
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: _togglePreview,
                icon: Icon(_previewOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down),
                label: Text(l10n.bugReportPreviewShow),
              ),
              if (_previewOpen && _preview != null)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _preview!,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _sending ? null : () => Navigator.of(context).pop(),
                    child: Text(l10n.bugReportCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: Text(l10n.bugReportSend),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
