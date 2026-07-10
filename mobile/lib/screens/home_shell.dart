import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../storage/local_db.dart';
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

  @override
  void initState() {
    super.initState();
    _triggerSync();
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
        children: const [
          DashboardScreen(),
          StatisticsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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
