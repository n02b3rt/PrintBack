import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../onboarding/permission_priming.dart';
import '../widgets/gradient_background.dart';
import 'home_shell.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  bool _scanning = false;
  bool _connecting = false;
  String? _error;
  List<ScanResult> _results = [];

  Future<void> _startScan() async {
    // Explain and request BLE permission before the raw system prompt, and
    // handle a denial gracefully (report 3.3) rather than just scanning and
    // failing with a terse message.
    if (!await primeAndRequestBlePermission(context)) {
      if (mounted) {
        setState(() =>
            _error = AppLocalizations.of(context)!.bluetoothPermissionDenied);
      }
      return;
    }
    if (!mounted) return;
    // Offer to turn Bluetooth on if it's off, before scanning finds nothing.
    if (!await context.read<BleService>().ensureAdapterOn()) {
      if (mounted) {
        setState(() =>
            _error = AppLocalizations.of(context)!.bluetoothOffHint);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _error = null;
      _results = [];
    });
    final ble = context.read<BleService>();
    final sub = ble.scanResults.listen((results) {
      setState(() => _results = results);
    });
    try {
      await ble.scan();
      await Future.delayed(const Duration(seconds: 10));
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context)!.bluetoothPermissionDenied);
      }
    }
    await sub.cancel();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    final ble = context.read<BleService>();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ble.connect(device);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
    } catch (e, st) {
      // Raw exception text stays in the log only; the user sees one of
      // three plain-language messages (10d).
      debugPrint('BLE connect failed: $e\n$st');
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _error = _friendlyError(e, l10n);
        _connecting = false;
      });
    }
  }

  /// Maps a connect() failure onto a message a non-technical user can act
  /// on. A permission error tells them where to fix it; a missing
  /// characteristic/service (connect()'s own StateError when the GATT
  /// table isn't ours) means they tapped the wrong device; anything else
  /// is a generic "check the LED and retry".
  String _friendlyError(Object e, AppLocalizations l10n) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('permission')) {
      return l10n.bluetoothPermissionDenied;
    }
    if (e is StateError &&
        (msg.contains('characteristic') || msg.contains('service'))) {
      return l10n.notPrintBackDevice;
    }
    return l10n.connectionFailedHint;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pairingTitle)),
      body: GradientBackground(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.pairingInstruction),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: (_scanning || _connecting) ? null : _startScan,
                child: Text(_scanning ? l10n.scanning : l10n.scanButton),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              if (_connecting) const LinearProgressIndicator(),
              Expanded(
                child: _results.isEmpty
                    ? Center(
                        child:
                            Text(_scanning ? l10n.scanning : l10n.noDevicesFound),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final result = _results[index];
                          final name = result.device.platformName.isNotEmpty
                              ? result.device.platformName
                              : result.device.remoteId.str;
                          return ListTile(
                            title: Text(name),
                            subtitle: Text('RSSI: ${result.rssi}'),
                            onTap:
                                _connecting ? null : () => _connect(result.device),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
