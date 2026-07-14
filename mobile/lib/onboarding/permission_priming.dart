import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/gradient_background.dart';

/// Explains why Bluetooth is needed *before* triggering the system prompt,
/// then requests it, and on denial routes to system settings. Returns true
/// iff permission ends up granted. The uncontextualised system prompt
/// ("Allow nearby device scanning?") has a high deny rate, and Android
/// often won't show it a second time - so priming first, then handling
/// denial gracefully, is the difference between a smooth pairing and a
/// dead end for a non-technical user (report 3.3).
///
/// On non-Android platforms permission is implicit (iOS prompts off its
/// Info.plist string), so this returns true immediately.
Future<bool> primeAndRequestBlePermission(BuildContext context) async {
  if (defaultTargetPlatform != TargetPlatform.android) return true;
  if (await Permission.bluetoothScan.isGranted &&
      await Permission.bluetoothConnect.isGranted) {
    return true;
  }
  if (!context.mounted) return false;
  final granted = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const PermissionPrimingScreen()),
  );
  return granted ?? false;
}

class PermissionPrimingScreen extends StatefulWidget {
  const PermissionPrimingScreen({super.key});

  @override
  State<PermissionPrimingScreen> createState() =>
      _PermissionPrimingScreenState();
}

class _PermissionPrimingScreenState extends State<PermissionPrimingScreen> {
  bool _denied = false;
  bool _busy = false;

  Future<void> _request() async {
    setState(() => _busy = true);
    final granted = await context.read<BleService>().requestPermissions();
    if (!mounted) return;
    if (granted) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _denied = true;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _denied ? Icons.bluetooth_disabled : Icons.bluetooth,
                    size: 56,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  _denied ? l10n.permissionDeniedTitle : l10n.permissionPrimingTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  _denied ? l10n.permissionDeniedBody : l10n.permissionPrimingBody,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 40),
                if (_denied) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => openAppSettings(),
                      child: Text(l10n.openSystemSettings),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.cancelButton),
                  ),
                ] else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _request,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.permissionPrimingUnderstand),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
