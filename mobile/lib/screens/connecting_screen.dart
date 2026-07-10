import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import 'dashboard_screen.dart';
import 'pairing_screen.dart';

/// Shown briefly at app launch while trying to reconnect to an
/// already-bonded device automatically - no need to re-scan every time
/// the app opens just because it's already paired. Falls back to the
/// manual pairing screen if nothing's found nearby or the attempt fails.
class ConnectingScreen extends StatefulWidget {
  const ConnectingScreen({super.key});

  @override
  State<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends State<ConnectingScreen> {
  @override
  void initState() {
    super.initState();
    _tryConnect();
  }

  Future<void> _tryConnect() async {
    final ble = context.read<BleService>();
    final device = await ble.tryAutoConnect();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            device != null ? const DashboardScreen() : const PairingScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.autoConnecting),
          ],
        ),
      ),
    );
  }
}
