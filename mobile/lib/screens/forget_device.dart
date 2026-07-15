import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../storage/local_db.dart';
import 'pairing_screen.dart';

/// Shared "forget device" flow, used from both Settings and the device
/// screen: confirm (optionally wiping the device's cached data), drop the
/// active device, remind the user to remove the OS Bluetooth bond (an app
/// can't), and return to pairing.
Future<void> forgetDevice(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final ble = context.read<BleService>();
  final deviceId = ble.activeDeviceId;
  // false = forget but keep data; true = also wipe it; null = cancel.
  final choice = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.forgetDeviceTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.forgetDeviceBody),
          const SizedBox(height: 12),
          Text(l10n.forgetDeviceUnbondHint,
              style: Theme.of(ctx).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: Text(l10n.cancelButton),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.forgetDeviceKeepData),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.forgetDeviceDeleteData),
        ),
      ],
    ),
  );
  if (choice == null) return;
  if (choice && deviceId != null) {
    await LocalDb().deleteDevice(deviceId);
  }
  await ble.forgetActiveDevice();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const PairingScreen()),
    (route) => false,
  );
}
