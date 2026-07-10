import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/device_config.dart';
import '../theme/theme_controller.dart';
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
  bool _loading = true;
  bool _saving = false;
  String? _error;

  int _rssiFloor = _rssiFloorMin;
  int _returningWindowDays = _returningWindowMin;

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
      _rssiFloor = config.rssiFloor.clamp(_rssiFloorMin, _rssiFloorMax);
      _returningWindowDays =
          config.returningWindowDays.clamp(_returningWindowMin, _returningWindowMax);
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
    final ble = context.read<BleService>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final config = DeviceConfig(
        rssiFloor: _rssiFloor,
        returningWindowDays: _returningWindowDays,
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.watch<BleService>();
    final themeController = context.watch<ThemeController>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l10n.appearanceSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                        value: ThemeMode.light, label: Text(l10n.themeLight)),
                    ButtonSegment(
                        value: ThemeMode.dark, label: Text(l10n.themeDark)),
                    ButtonSegment(
                        value: ThemeMode.system, label: Text(l10n.themeSystem)),
                  ],
                  selected: {themeController.mode},
                  onSelectionChanged: (s) => themeController.setMode(s.first),
                ),
                const SizedBox(height: 24),
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
                Text(l10n.detectionSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_error != null) ...[
                  Text(_error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                ],
                Text('${l10n.rssiFloorLabel}: $_rssiFloor dBm'),
                Slider(
                  value: _rssiFloor.toDouble(),
                  min: _rssiFloorMin.toDouble(),
                  max: _rssiFloorMax.toDouble(),
                  divisions: _rssiFloorMax - _rssiFloorMin,
                  label: '$_rssiFloor dBm',
                  onChanged: (v) => setState(() => _rssiFloor = v.round()),
                ),
                const SizedBox(height: 8),
                Text('${l10n.returningWindowLabel}: $_returningWindowDays'),
                Slider(
                  value: _returningWindowDays.toDouble(),
                  min: _returningWindowMin.toDouble(),
                  max: _returningWindowMax.toDouble(),
                  divisions: _returningWindowMax - _returningWindowMin,
                  label: '$_returningWindowDays',
                  onChanged: (v) =>
                      setState(() => _returningWindowDays = v.round()),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.saveButton),
                ),
              ],
            ),
    );
  }
}
