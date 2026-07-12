import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';

/// Persistent, visible connection/sync status - explicit confirmation
/// the device is paired and connected (not just silently assumed), and
/// real feedback while a sync is actually moving data instead of a
/// button that fires-and-forgets with no visible result. When
/// disconnected (offline mode), offers a [Connect] button that runs a
/// background reconnect without leaving the screen.
class SyncStatusBanner extends StatefulWidget {
  const SyncStatusBanner({super.key});

  @override
  State<SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<SyncStatusBanner> {
  bool _connecting = false;

  Future<void> _reconnect() async {
    setState(() => _connecting = true);
    try {
      await context.read<BleService>().tryAutoConnect();
    } catch (_) {
      // tryAutoConnect() already swallows its own failures and returns
      // null; a throw here would only be an unexpected one. Either way the
      // provider's connectionState drives the banner, so nothing to do but
      // stop showing the local spinner.
    }
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.watch<BleService>();
    final connected = ble.connectionState == BluetoothConnectionState.connected;

    final String statusText;
    if (ble.isSyncing) {
      statusText = l10n.syncingNow;
    } else if (ble.lastSyncCompleted != null) {
      statusText =
          l10n.lastSyncedAgo(_relativeTime(ble.lastSyncCompleted!, l10n));
    } else {
      statusText = l10n.neverSynced;
    }

    final accent = connected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (ble.isSyncing)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          else
            Icon(connected ? Icons.verified : Icons.error_outline,
                size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? l10n.pairedAndConnected : l10n.notConnected,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(statusText, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (!connected) ...[
            const SizedBox(width: 8),
            if (_connecting)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent),
              )
            else
              TextButton(
                onPressed: _reconnect,
                child: Text(l10n.connectButton),
              ),
          ],
        ],
      ),
    );
  }

  String _relativeTime(DateTime t, AppLocalizations l10n) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return l10n.justNow;
    if (diff.inMinutes < 60) return l10n.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.hoursAgo(diff.inHours);
    return l10n.daysAgo(diff.inDays);
  }
}
