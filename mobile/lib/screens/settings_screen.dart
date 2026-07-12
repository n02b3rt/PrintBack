import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/device_config.dart';
import '../theme/theme_controller.dart';
import '../storage/local_db.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import 'home_shell.dart';
import 'pairing_screen.dart';

/// Mirrors firmware/main/runtime_config_parse.h - single source of truth
/// for the valid CONFIG ranges, kept in sync by hand since the phone has
/// no way to query them from the device.
const _rssiFloorMin = -100;
const _rssiFloorMax = -20;
const _returningWindowMin = 1;
const _returningWindowMax = 90;

/// Human-facing counting-range presets over the raw RSSI floor - a shop
/// owner picks "at the entrance / whole venue / wide", not a dBm number
/// (the raw slider still lives under "Advanced"). Values match the ranges
/// the report calibrated (raport 2.5).
enum _RangePreset { entrance, venue, wide, custom }

const _presetRssi = {
  _RangePreset.entrance: -60,
  _RangePreset.venue: -75,
  _RangePreset.wide: -85,
};

_RangePreset _presetForRssi(int rssi) {
  for (final e in _presetRssi.entries) {
    if (e.value == rssi) return e.key;
  }
  return _RangePreset.custom;
}

const _returningWindowPresets = [7, 14, 30];

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
  // The rssi floor as loaded from the device, to detect a real range
  // change on save (so the confirmation dialog only appears when the
  // counting behaviour actually changes).
  int _loadedRssiFloor = _rssiFloorMin;
  bool _advancedOpen = false;

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
    // Offline there's no device to read config from - that's a normal
    // state now (offline mode), not an error. Leave the controls at
    // defaults and disabled; the section shows a "requires connection"
    // note instead of a scary red failure.
    if (ble.connectionState != BluetoothConnectionState.connected) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final config = await ble.readConfig();
      _rssiFloor = config.rssiFloor.clamp(_rssiFloorMin, _rssiFloorMax);
      _loadedRssiFloor = _rssiFloor;
      _returningWindowDays =
          config.returningWindowDays.clamp(_returningWindowMin, _returningWindowMax);
      _advancedOpen = _presetForRssi(_rssiFloor) == _RangePreset.custom;
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

  Future<void> _forgetDevice() async {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.read<BleService>();
    final deviceId = ble.activeDeviceId;
    // keep = forget but leave cached data; delete = also wipe it; null = cancel.
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
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PairingScreen()),
      (route) => false,
    );
  }

  Future<void> _save() async {
    final ble = context.read<BleService>();
    final l10n = AppLocalizations.of(context)!;
    // Changing the range alters counting from now on - confirm it, since a
    // shop owner nudging a control shouldn't silently reshape their data.
    if (_rssiFloor != _loadedRssiFloor) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.rangeChangeConfirmTitle),
          content: Text(l10n.rangeChangeConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.confirmButton),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
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
      _loadedRssiFloor = _rssiFloor;
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

  String _rangeDescription(AppLocalizations l10n, _RangePreset preset) {
    switch (preset) {
      case _RangePreset.entrance:
        return l10n.rangeEntranceDesc;
      case _RangePreset.venue:
        return l10n.rangeVenueDesc;
      case _RangePreset.wide:
        return l10n.rangeWideDesc;
      case _RangePreset.custom:
        return l10n.rangeCustomDesc;
    }
  }

  Widget _detectionCard(BuildContext context, AppLocalizations l10n,
      {required bool enabled}) {
    final preset = _presetForRssi(_rssiFloor);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.rangeLabel,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          SegmentedButton<_RangePreset>(
            segments: [
              ButtonSegment(
                  value: _RangePreset.entrance, label: Text(l10n.rangeEntrance)),
              ButtonSegment(
                  value: _RangePreset.venue, label: Text(l10n.rangeVenue)),
              ButtonSegment(
                  value: _RangePreset.wide, label: Text(l10n.rangeWide)),
              if (preset == _RangePreset.custom)
                ButtonSegment(
                    value: _RangePreset.custom, label: Text(l10n.rangeCustom)),
            ],
            selected: {preset},
            onSelectionChanged: enabled
                ? (s) {
                    final p = s.first;
                    final rssi = _presetRssi[p];
                    setState(() {
                      if (rssi != null) {
                        _rssiFloor = rssi;
                      } else {
                        // "Custom" just reveals the raw slider - it has no
                        // single value of its own.
                        _advancedOpen = true;
                      }
                    });
                  }
                : null,
          ),
          const SizedBox(height: 8),
          Text(_rangeDescription(l10n, preset),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: _advancedOpen,
              title: Text(l10n.advancedLabel,
                  style: Theme.of(context).textTheme.bodyMedium),
              children: [
                Text('${l10n.rssiFloorLabel}: $_rssiFloor dBm'),
                Slider(
                  value: _rssiFloor.toDouble(),
                  min: _rssiFloorMin.toDouble(),
                  max: _rssiFloorMax.toDouble(),
                  divisions: _rssiFloorMax - _rssiFloorMin,
                  label: '$_rssiFloor dBm',
                  onChanged: enabled
                      ? (v) => setState(() => _rssiFloor = v.round())
                      : null,
                ),
              ],
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),
          Text('${l10n.returningWindowLabel}: $_returningWindowDays'),
          Text(l10n.returningWindowSubtitle,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final d in _returningWindowPresets)
                ChoiceChip(
                  label: Text('$d'),
                  selected: _returningWindowDays == d,
                  onSelected: enabled
                      ? (_) => setState(() => _returningWindowDays = d)
                      : null,
                ),
            ],
          ),
          Slider(
            value: _returningWindowDays.toDouble(),
            min: _returningWindowMin.toDouble(),
            max: _returningWindowMax.toDouble(),
            divisions: _returningWindowMax - _returningWindowMin,
            label: '$_returningWindowDays',
            onChanged: enabled
                ? (v) => setState(() => _returningWindowDays = v.round())
                : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.watch<BleService>();
    final connected =
        ble.connectionState == BluetoothConnectionState.connected;
    final themeController = context.watch<ThemeController>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: GradientBackground(
        child: _loading
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
                          value: ThemeMode.system,
                          label: Text(l10n.themeSystem)),
                    ],
                    selected: {themeController.mode},
                    onSelectionChanged: (s) => themeController.setMode(s.first),
                  ),
                  const SizedBox(height: 24),
                  Text(l10n.deviceSectionTitle,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        ListTile(
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
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(l10n.noOtherDevices,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          )
                        else
                          ..._otherDevices.map(
                            (d) => ListTile(
                              leading: const Icon(Icons.bluetooth),
                              title: Text(
                                d.platformName.isNotEmpty
                                    ? d.platformName
                                    : d.remoteId.str,
                              ),
                              onTap: _switching ? null : () => _switchTo(d),
                            ),
                          ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.link_off,
                              color: Theme.of(context).colorScheme.error),
                          title: Text(
                            l10n.forgetDevice,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error),
                          ),
                          onTap: ble.activeDeviceId == null || _switching
                              ? null
                              : _forgetDevice,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(l10n.detectionSectionTitle,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_error != null) ...[
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 16),
                  ],
                  if (!connected) ...[
                    Text(l10n.requiresConnection,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                  ],
                  _detectionCard(context, l10n, enabled: connected),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: (_saving || !connected) ? null : _save,
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
      ),
    );
  }
}
