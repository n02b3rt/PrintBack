import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/aggregate.dart';
import '../screens/home_shell.dart';
import '../widgets/device_illustration.dart';
import '../widgets/gradient_background.dart';
import 'onboarding_flags.dart';
import 'permission_priming.dart';
import 'wizard_rescue.dart';

/// The guided 4-step pairing flow, the heart of onboarding (report 3.4).
/// One action per screen, plain language, and an on-screen LED that
/// behaves exactly like the physical one (DeviceIllustration mirrors
/// firmware/main/ui.c) so a non-technical owner can match "my device is
/// doing the same thing as the picture". Reuses BleService's existing
/// scan/connect/statsUpdates - no new BLE logic, just orchestration.
class PairingWizard extends StatefulWidget {
  const PairingWizard({super.key});

  @override
  State<PairingWizard> createState() => _PairingWizardState();
}

class _PairingWizardState extends State<PairingWizard> {
  // The device's pairing window; kept in sync with
  // CONFIG_PRINTBACK_PAIRING_WINDOW_SECONDS (firmware/sdkconfig.defaults).
  static const _pairingWindowSeconds = 60;

  int _step = 1; // 1..4
  bool _rescue = false;
  int _rescueAttempts = 0;

  Timer? _countdown;
  int _secondsLeft = _pairingWindowSeconds;

  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _scanTimeout;
  List<BluetoothDevice> _multipleFound = [];
  bool _connecting = false;

  StreamSubscription<Aggregate>? _syncSub;
  final Set<String> _syncedDays = {};

  @override
  void dispose() {
    _countdown?.cancel();
    _scanTimeout?.cancel();
    _scanSub?.cancel();
    _syncSub?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _countdown?.cancel();
    _secondsLeft = _pairingWindowSeconds;
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  void _toStep2() {
    setState(() => _step = 2);
    _startCountdown();
  }

  Future<void> _buttonPressed() async {
    _countdown?.cancel();
    setState(() {
      _step = 3;
      _rescue = false;
      _multipleFound = [];
    });
    await _startScan();
  }

  Future<void> _startScan() async {
    if (!await primeAndRequestBlePermission(context)) {
      if (mounted) _toRescue();
      return;
    }
    if (!mounted) return;
    final ble = context.read<BleService>();
    // Offer to turn Bluetooth on if it's off; on decline fall to the rescue
    // checklist (which itself reminds the user to enable Bluetooth).
    if (!await ble.ensureAdapterOn()) {
      if (mounted) _toRescue();
      return;
    }
    if (!mounted) return;
    await _scanSub?.cancel();
    _scanSub = ble.scanResults.listen((results) {
      if (_connecting || !mounted) return;
      if (results.length == 1) {
        _connectTo(results.first.device);
      } else if (results.length > 1) {
        setState(() => _multipleFound = results.map((r) => r.device).toList());
      }
    });
    _scanTimeout?.cancel();
    _scanTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && _step == 3 && !_connecting && _multipleFound.isEmpty) {
        _toRescue();
      }
    });
    try {
      await ble.scan(timeout: const Duration(seconds: 15));
    } catch (_) {
      if (mounted && !_connecting) _toRescue();
    }
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    if (_connecting) return;
    _connecting = true;
    final ble = context.read<BleService>();
    _scanTimeout?.cancel();
    await _scanSub?.cancel();
    try {
      await ble.stopScan();
    } catch (_) {}
    try {
      await ble.connect(device);
      if (!mounted) return;
      _watchFirstSync();
      setState(() => _step = 4);
    } catch (_) {
      _connecting = false;
      if (mounted) _toRescue();
    }
  }

  void _watchFirstSync() {
    final ble = context.read<BleService>();
    _syncSub?.cancel();
    _syncSub = ble.statsUpdates.listen((agg) {
      // Count distinct daily records as they stream in, so step 4 shows
      // real progress ("N days downloaded") rather than a dead spinner.
      if (agg.hour == null && !agg.isSyncEndMarker) {
        if (mounted) setState(() => _syncedDays.add(agg.date));
      }
    });
  }

  void _toRescue() {
    _scanTimeout?.cancel();
    _scanSub?.cancel();
    _connecting = false;
    setState(() {
      _rescue = true;
      _rescueAttempts++;
    });
  }

  void _retry() {
    setState(() {
      _rescue = false;
      _multipleFound = [];
    });
    _toStep2();
  }

  Future<void> _finish() async {
    await OnboardingFlags.setOnboardingDone();
    if (!mounted) return;
    // Coach marks show on the first dashboard (handled in 11d).
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeShell()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              _ProgressDots(step: _step),
              Expanded(
                child: _rescue
                    ? WizardRescue(attempts: _rescueAttempts, onRetry: _retry)
                    : _buildStep(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case 1:
        return _StepScaffold(
          led: LedState.boot,
          title: AppLocalizations.of(context)!.wizardStep1Title,
          body: AppLocalizations.of(context)!.wizardStep1Body,
          cta: AppLocalizations.of(context)!.wizardStep1Cta,
          onCta: _toStep2,
        );
      case 2:
        final l10n = AppLocalizations.of(context)!;
        return _StepScaffold(
          led: LedState.pairing,
          title: l10n.wizardStep2Title,
          body: l10n.wizardStep2Body,
          extra: Text(
            l10n.wizardStep2Counter(_secondsLeft.clamp(0, _pairingWindowSeconds)),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          cta: l10n.wizardStep2Cta,
          onCta: _buttonPressed,
        );
      case 3:
        return _buildScanning(context);
      case 4:
      default:
        return _buildConnected(context);
    }
  }

  Widget _buildScanning(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_multipleFound.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(l10n.wizardStep3Pick,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  for (final d in _multipleFound)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(d.platformName.isNotEmpty
                          ? d.platformName
                          : d.remoteId.str),
                      onTap: () => _connectTo(d),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 96,
            height: 96,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 32),
          Text(l10n.wizardStep3Title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Text(l10n.wizardStep3Body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }

  Widget _buildConnected(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 150, child: DeviceIllustration(led: LedState.syncing, size: 150)),
          const SizedBox(height: 24),
          Icon(Icons.check_circle,
              size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(l10n.wizardStep4Title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(l10n.wizardStep4Body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          Text(l10n.wizardStep4Progress(_syncedDays.length),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _finish,
              child: Text(l10n.wizardStep4Cta),
            ),
          ),
        ],
      ),
    );
  }
}

/// A shared layout for the instructional steps: the drawn device up top,
/// a title, a body line, an optional extra (e.g. the countdown), and one
/// primary button.
class _StepScaffold extends StatelessWidget {
  final LedState led;
  final String title;
  final String body;
  final Widget? extra;
  final String cta;
  final VoidCallback onCta;

  const _StepScaffold({
    required this.led,
    required this.title,
    required this.body,
    required this.cta,
    required this.onCta,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 170, child: DeviceIllustration(led: led, size: 170)),
          const SizedBox(height: 32),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Text(body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge),
          if (extra != null) ...[
            const SizedBox(height: 20),
            extra!,
          ],
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onCta, child: Text(cta)),
          ),
        ],
      ),
    );
  }
}

class _ProgressDots extends StatelessWidget {
  final int step;
  const _ProgressDots({required this.step});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 4; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == step ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i <= step
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(AppLocalizations.of(context)!.wizardStepCounter(step),
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
