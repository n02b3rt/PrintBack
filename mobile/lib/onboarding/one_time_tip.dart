import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// A small educational tooltip shown once (the caller gates on a
/// shared_preferences flag and marks it seen). Drip education - one idea
/// at the moment it's first relevant - rather than a wall of text up front
/// (report 3.6).
Future<void> showOneTimeTip(
  BuildContext context, {
  required String title,
  required String body,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.gotItButton),
        ),
      ],
    ),
  );
}
