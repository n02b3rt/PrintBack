import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/device_config.dart';
import 'home_shell.dart';

/// Mirrors firmware/main/runtime_config_parse.h - single source of truth
/// for the valid CONFIG ranges, kept in sync by hand since the phone has
/// no way to query them from the device.
const _rssiFloorMin = -100;
const _rssiFloorMax = -20;
const _returningWindowMin = 1;
const _returningWindowMax = 90;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _rssiController = TextEditingController();
  final _returningWindowController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  List<BluetoothDevice> _otherDevices = [];
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadOtherDevices();
  }

  Future<void> _load() async {
    final ble = context.read<BleService>();
    try {
      final config = await ble.readConfig();
      _rssiController.text = config.rssiFloor.toString();
      _returningWindowController.text = config.returningWindowDays.toString();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.settingsLoadFailed);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadOtherDevices() async {
    final ble = context.read<BleService>();
    final known = await ble.knownDevices();
    if (!mounted) return;
    setState(() {
      _otherDevices =
          known.where((d) => d.remoteId != ble.device?.remoteId).toList();
    });
  }

  Future<void> _switchTo(BluetoothDevice device) async {
    final ble = context.read<BleService>();
    setState(() => _switching = true);
    try {
      await ble.connect(device);
      if (!mounted) return;
      // A fresh HomeShell (and the screens inside it) picks up the new
      // device id in its own initState() - simpler and more robust than
      // trying to hot-patch the already-showing tabs' state from here.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _switching = false;
        _error = AppLocalizations.of(context)!.switchDeviceFailed;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ble = context.read<BleService>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final config = DeviceConfig(
        rssiFloor: int.parse(_rssiController.text),
        returningWindowDays: int.parse(_returningWindowController.text),
      );
      await ble.writeConfig(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.settingsSaved)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.settingsSaveFailed);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  void dispose() {
    _rssiController.dispose();
    _returningWindowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.watch<BleService>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l10n.deviceSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bluetooth_connected),
                  title: Text(
                    ble.device?.platformName.isNotEmpty == true
                        ? ble.device!.platformName
                        : (ble.device?.remoteId.str ?? l10n.notConnected),
                  ),
                  subtitle: Text(l10n.currentDevice),
                ),
                if (_switching) const LinearProgressIndicator(),
                if (_otherDevices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(l10n.noOtherDevices,
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                else
                  ..._otherDevices.map(
                    (d) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        d.platformName.isNotEmpty ? d.platformName : d.remoteId.str,
                      ),
                      onTap: _switching ? null : () => _switchTo(d),
                    ),
                  ),
                const SizedBox(height: 24),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _rssiController,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: l10n.rssiFloorLabel),
                        validator: (value) {
                          final n = int.tryParse(value ?? '');
                          if (n == null || n < _rssiFloorMin || n > _rssiFloorMax) {
                            return '$_rssiFloorMin..$_rssiFloorMax';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _returningWindowController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: l10n.returningWindowLabel),
                        validator: (value) {
                          final n = int.tryParse(value ?? '');
                          if (n == null ||
                              n < _returningWindowMin ||
                              n > _returningWindowMax) {
                            return '$_returningWindowMin..$_returningWindowMax';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const CircularProgressIndicator()
                            : Text(l10n.saveButton),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
