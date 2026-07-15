import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/aggregate.dart';
import '../models/device_status.dart';
import '../widgets/device_illustration.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import 'forget_device.dart';

/// A Garmin-Connect-style device page: instead of a cryptic sync icon that
/// gives no feedback (and is dead when Bluetooth is off), the user opens
/// this screen to see the device, its live status (firmware / SD / uptime),
/// the connection state, and to sync with real progress or reconnect. All
/// reused from existing BleService plumbing - no new BLE logic, no firmware
/// change.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  DeviceStatus? _status;
  bool _loadingStatus = false;
  bool _connecting = false;

  StreamSubscription<Aggregate>? _syncSub;
  final Set<String> _syncedDays = {};

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleService>();
    // Count distinct daily records as they stream in during a sync, so the
    // "Sync now" button shows live progress instead of a dead spinner.
    _syncSub = ble.statsUpdates.listen((agg) {
      if (agg.hour == null && !agg.isSyncEndMarker && mounted) {
        setState(() => _syncedDays.add(agg.date));
      }
    });
    _refreshStatus();
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final ble = context.read<BleService>();
    if (!ble.isConnectedReady) {
      if (mounted) setState(() => _status = null);
      return;
    }
    setState(() => _loadingStatus = true);
    final s = await ble.readStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      _loadingStatus = false;
    });
  }

  Future<void> _sync() async {
    setState(() => _syncedDays.clear());
    await context.read<BleService>().requestSync(0);
  }

  Future<void> _connect() async {
    final ble = context.read<BleService>();
    setState(() => _connecting = true);
    // Bluetooth off -> pop the system enable dialog rather than failing
    // silently (the whole reason for this screen).
    if (!await ble.ensureAdapterOn()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.bluetoothOffHint)),
        );
        setState(() => _connecting = false);
      }
      return;
    }
    await ble.tryAutoConnect();
    if (!mounted) return;
    setState(() => _connecting = false);
    _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ble = context.watch<BleService>();
    final connected = ble.isConnectedReady;
    final scheme = Theme.of(context).colorScheme;

    final String stateText;
    if (connected) {
      stateText = l10n.pairedAndConnected;
    } else if (ble.isReconnecting) {
      stateText = l10n.reconnecting;
    } else {
      stateText = l10n.notConnected;
    }
    final accent = connected ? scheme.primary : scheme.error;
    final name = ble.device?.platformName.isNotEmpty == true
        ? ble.device!.platformName
        : (ble.activeDeviceId ?? l10n.notConnected);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.deviceScreenTitle)),
      body: GradientBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Header: drawn device + name + connection state.
            Center(
              child: DeviceIllustration(
                led: connected ? LedState.idle : LedState.off,
                size: 140,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(name, style: Theme.of(context).textTheme.titleLarge),
            ),
            Center(
              child: Text(stateText,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: accent)),
            ),
            const SizedBox(height: 24),

            // Status card.
            Text(l10n.deviceStatusTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            GlassCard(child: _statusBody(context, l10n, connected)),
            const SizedBox(height: 24),

            // Sync / connect section.
            _syncSection(context, l10n, ble, connected),
            const SizedBox(height: 24),

            // Restart help: a 10s button hold reboots the device in the
            // field (firmware ui.c hold-to-restart), no PC/power-unplug
            // needed - the LED counts the hold down (red) and confirms
            // (white flash). Requires the firmware build carrying that
            // gesture to be flashed.
            Text(l10n.restartTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.restart_alt),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.restartBody)),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Forget device (shared with Settings).
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ListTile(
                leading: Icon(Icons.link_off, color: scheme.error),
                title: Text(l10n.forgetDevice,
                    style: TextStyle(color: scheme.error)),
                onTap: ble.activeDeviceId == null
                    ? null
                    : () => forgetDevice(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBody(BuildContext context, AppLocalizations l10n, bool connected) {
    if (!connected) {
      return Text(l10n.statusOfflineHint,
          style: Theme.of(context).textTheme.bodyMedium);
    }
    if (_loadingStatus && _status == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final s = _status;
    if (s == null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.statusOfflineHint),
          IconButton(onPressed: _refreshStatus, icon: const Icon(Icons.refresh)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusRow(l10n.statusFw, s.fw),
        _statusRow(l10n.statusSdCard, s.sdOk ? l10n.statusSdOk : l10n.statusSdError),
        _statusRow(l10n.statusSdFree, '${s.sdFreeMb} MB'),
        _statusRow(l10n.statusUptime, _uptime(s.uptimeS)),
        if (s.whitelistCount != null) ...[
          _statusRow(l10n.statusWhitelist, '${s.whitelistCount}'),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text(
              l10n.statusWhitelistHint,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
              onPressed: _refreshStatus, icon: const Icon(Icons.refresh)),
        ),
      ],
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _syncSection(
      BuildContext context, AppLocalizations l10n, BleService ble, bool connected) {
    if (!connected) {
      // Offline: the action is to (re)connect, not sync.
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _connecting ? null : _connect,
          icon: _connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.bluetooth_searching),
          label: Text(l10n.connectButton),
        ),
      );
    }

    final String subtitle;
    if (ble.isSyncing) {
      subtitle = l10n.syncDownloading(_syncedDays.length);
    } else if (ble.lastSyncCompleted != null) {
      subtitle = l10n.lastSyncedAgo(_relativeTime(ble.lastSyncCompleted!, l10n));
    } else {
      subtitle = l10n.neverSynced;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: ble.isSyncing ? null : _sync,
          icon: ble.isSyncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync),
          label: Text(l10n.syncNowButton),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  String _uptime(int seconds) {
    if (seconds >= 3600) {
      final h = seconds ~/ 3600;
      final m = (seconds % 3600) ~/ 60;
      return '${h}h ${m}min';
    }
    if (seconds >= 60) return '${seconds ~/ 60}min';
    return '${seconds}s';
  }

  String _relativeTime(DateTime t, AppLocalizations l10n) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return l10n.justNow;
    if (diff.inMinutes < 60) return l10n.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.hoursAgo(diff.inHours);
    return l10n.daysAgo(diff.inDays);
  }
}
