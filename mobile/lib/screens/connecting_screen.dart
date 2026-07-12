import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../storage/local_db.dart';
import '../widgets/gradient_background.dart';
import 'home_shell.dart';
import 'pairing_screen.dart';

/// Shown briefly at app launch while trying to reconnect to an
/// already-bonded device automatically - no need to re-scan every time
/// the app opens just because it's already paired. If the auto-connect
/// fails but the active device has cached aggregates, drops straight into
/// the dashboard in offline mode instead of forcing the pairing screen;
/// only a device with no cached data at all falls back to pairing.
class ConnectingScreen extends StatefulWidget {
  const ConnectingScreen({super.key});

  @override
  State<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends State<ConnectingScreen> {
  final _localDb = LocalDb();

  /// Which phase of the auto-connect the status line describes. Starts on
  /// the fast systemDevices() lookup, then the slower real scan
  /// (tryAutoConnect() runs both in sequence internally - this mirrors
  /// that so the user sees why it's taking a moment).
  bool _scanningPhase = false;

  /// After ~8s of trying, offer a manual "just show me the cached data"
  /// escape hatch - but only if there's actually cached data to show.
  bool _offerOffline = false;

  Timer? _phaseTimer;
  Timer? _offlineTimer;

  @override
  void initState() {
    super.initState();
    _phaseTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _scanningPhase = true);
    });
    _offlineTimer = Timer(const Duration(seconds: 8), _maybeOfferOffline);
    _tryConnect();
  }

  Future<void> _maybeOfferOffline() async {
    final ble = context.read<BleService>();
    final id = ble.activeDeviceId;
    final has = id != null && await _localDb.hasAnyData(id);
    if (!mounted) return;
    setState(() => _offerOffline = has);
  }

  Future<void> _tryConnect() async {
    final ble = context.read<BleService>();
    final device = await ble.tryAutoConnect();
    if (!mounted) return;
    if (device != null) {
      _goTo(const HomeShell());
      return;
    }
    // Auto-connect failed. If this device already has cached data, show it
    // offline rather than forcing a re-pair; otherwise there's genuinely
    // nothing to show, so go pair.
    final id = ble.activeDeviceId;
    final hasData = id != null && await _localDb.hasAnyData(id);
    if (!mounted) return;
    _goTo(hasData ? const HomeShell() : const PairingScreen());
  }

  void _goTo(Widget screen) {
    _phaseTimer?.cancel();
    _offlineTimer?.cancel();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  void dispose() {
    _phaseTimer?.cancel();
    _offlineTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status =
        _scanningPhase ? l10n.scanningNearby : l10n.searchingKnownDevices;
    return Scaffold(
      body: GradientBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(status),
              if (_offerOffline) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  icon: const Icon(Icons.history),
                  label: Text(l10n.browseOffline),
                  onPressed: () => _goTo(const HomeShell()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
