import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import 'dashboard_screen.dart';

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
    setState(() {
      _scanning = true;
      _error = null;
      _results = [];
    });
    final ble = context.read<BleService>();
    final sub = ble.scan().listen((results) {
      setState(() => _results = results);
    });
    await Future.delayed(const Duration(seconds: 10));
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
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
      );
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _error = l10n.connectionFailed;
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pairingTitle)),
      body: Padding(
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
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            if (_connecting) const LinearProgressIndicator(),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(_scanning ? l10n.scanning : l10n.noDevicesFound),
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
                          onTap: _connecting ? null : () => _connect(result.device),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
