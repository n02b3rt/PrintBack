import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../onboarding/coach_marks.dart';
import '../onboarding/onboarding_flags.dart';
import '../onboarding/one_time_tip.dart';
import '../services/demo_data.dart';
import '../services/shake_detector.dart';
import '../services/weekly_notification.dart';
import '../storage/local_db.dart';
import 'bug_report_sheet.dart';
import 'dashboard_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';

/// Landing screen after any successful connection (fresh auto-connect,
/// manual pairing, or switching devices in Settings). Bottom-nav shell
/// over three tabs, `IndexedStack` so switching tabs doesn't lose each
/// screen's own state or re-trigger its initial load.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // Spotlight targets for the first-run coach marks (11d).
  final _kpiKey = GlobalKey();
  final _hourlyKey = GlobalKey();
  final _bannerKey = GlobalKey();
  final _navKey = GlobalKey();

  /// Shake 3x anywhere in the app to report a problem. The gesture only
  /// opens the consent sheet - nothing is collected or sent until the
  /// operator acts on it (services/bug_report.dart).
  late final ShakeDetector _shake;
  bool _bugSheetOpen = false;

  @override
  void initState() {
    super.initState();
    _triggerSync();
    _scheduleWeeklySummary();
    _shake = ShakeDetector(onShake: _onShake)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowCoachMarks());
  }

  @override
  void dispose() {
    _shake.stop();
    super.dispose();
  }

  Future<void> _onShake() async {
    if (_bugSheetOpen || !mounted) return;
    _bugSheetOpen = true;
    await showBugReportSheet(context);
    _bugSheetOpen = false;
  }

  /// Recomputes last week's footfall from the local db and (re)schedules
  /// the Monday-morning summary notification. Runs every launch (no
  /// background worker in v1); a snapshot at scheduling time is fine for a
  /// weekly nudge. Skipped when there's nothing to report or notifications
  /// aren't permitted.
  Future<void> _scheduleWeeklySummary() async {
    final deviceId = context.read<BleService>().activeDeviceId;
    if (deviceId == null) return;
    final now = DateTime.now();
    final rows = await LocalDb().dailyInRange(
      deviceId,
      _dateString(now.subtract(const Duration(days: 7))),
      _dateString(now),
    );
    final visitors = rows.fold<int>(0, (s, a) => s + a.unique);
    if (visitors <= 0 || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (!await WeeklyNotification.instance.requestPermission()) return;
    await WeeklyNotification.instance.scheduleWeekly(
      title: l10n.weeklyNotifTitle,
      body: l10n.weeklyNotifBody(visitors),
    );
  }

  static String _dateString(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// First time the dashboard is reached, run the coach-mark tour once the
  /// screen has settled a moment. Skipped for returning users (flag set)
  /// or if the user has already navigated away.
  /// A tour that points at the KPI cards and says "these are today's
  /// visitors" is useless when every card reads 0 - which is exactly the
  /// state a brand new user is in, since the device has had no time to see
  /// anyone yet. Offer the demo data first, so the tour explains something
  /// the operator can actually see. Declining is a first-class option: the
  /// tour still runs, just over the real (empty) panel.
  ///
  /// Returns once the user has decided; the tour starts afterwards either way.
  Future<void> _offerDemoForTutorial() async {
    final ble = context.read<BleService>();
    final deviceId = ble.activeDeviceId;
    if (deviceId == null || DemoData.isDemo(deviceId)) return;
    if (await LocalDb().hasAnyData(deviceId)) return; // real data: no need
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final wantsDemo = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tutorialDemoTitle),
        content: Text(l10n.tutorialDemoBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.tutorialDemoSkip),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.tutorialDemoAccept),
          ),
        ],
      ),
    );
    if (wantsDemo != true || !mounted) return;
    await DemoData.enable(ble);
    if (!mounted) return;
    // Every screen caches its own rows, so send them back through the shell
    // to re-read against the demo device.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeShell()),
      (r) => false,
    );
  }

  Future<void> _maybeShowCoachMarks() async {
    if (await OnboardingFlags.coachMarksDone()) return;
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted || _index != 0) return;
    await _offerDemoForTutorial();
    // Accepting the demo rebuilds the shell, and the fresh one runs its own
    // _maybeShowCoachMarks - this instance is gone, so stop here rather than
    // spotlighting keys that no longer belong to a live tree.
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    CoachMarks.show(
      context,
      [
        CoachTarget(_kpiKey, l10n.coachMarkKpi),
        CoachTarget(_hourlyKey, l10n.coachMarkHourly),
        CoachTarget(_bannerKey, l10n.coachMarkBanner),
        CoachTarget(_navKey, l10n.coachMarkNav),
      ],
      onDone: () => OnboardingFlags.setCoachMarksDone(true),
    );
  }

  /// First time the user opens the Statistics tab, explain the
  /// returning-rate stat once (report 3.6). Triggered from the nav handler
  /// (not the screen's initState) because the IndexedStack builds all tabs
  /// eagerly, so initState fires before the tab is ever seen. Gated on the
  /// coach-mark tour being done so tips don't stack on the first run.
  Future<void> _maybeShowReturningTip() async {
    if (!await OnboardingFlags.coachMarksDone()) return;
    if (await OnboardingFlags.returningRateTipSeen()) return;
    await OnboardingFlags.setReturningRateTipSeen();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showOneTimeTip(
      context,
      title: l10n.tipReturningRateTitle,
      body: l10n.tipReturningRateBody,
    );
  }

  /// Requests a backlog replay once per connection, picking up right
  /// where the local db already left off (docs/DATA_MODEL.md "BLE SYNC
  /// payload") - this is the "sometimes syncs on its own" half of the
  /// sync story. Results arrive later over statsUpdates; the manual
  /// "Synchronizuj teraz" action on Dashboard/Statystyki covers the
  /// Garmin-Connect-style "I want it right now" half.
  Future<void> _triggerSync() async {
    final ble = context.read<BleService>();
    final device = ble.device;
    if (device == null) return;
    final deviceId = device.remoteId.str;
    final newest = await LocalDb().newestDailyDate(deviceId);
    final sinceUnixDay = newest == null ? 0 : _unixDayFromDateString(newest) + 1;
    await ble.requestSync(sinceUnixDay);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(
            kpiKey: _kpiKey,
            hourlyKey: _hourlyKey,
            bannerKey: _bannerKey,
            onOpenStatistics: () => setState(() => _index = 1),
          ),
          const StatisticsScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: _navKey,
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          if (i == 1) _maybeShowReturningTip();
        },
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.home), label: l10n.navDashboard),
          NavigationDestination(
              icon: const Icon(Icons.bar_chart), label: l10n.navStatistics),
          NavigationDestination(
              icon: const Icon(Icons.settings), label: l10n.navSettings),
        ],
      ),
    );
  }
}

/// Days since 1970-01-01 UTC for a `YYYY-MM-DD` string, matching the
/// on-device `date_unix_day` unit (firmware/main/sd_paths.h).
int _unixDayFromDateString(String date) {
  final parts = date.split('-');
  final d =
      DateTime.utc(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  return d.difference(DateTime.utc(1970, 1, 1)).inDays;
}
