import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import 'settings_screen.dart';

/// Today's date as `YYYY-MM-DD`, matching docs/DATA_MODEL.md's STATS
/// `date` field format.
String _todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _localDb = LocalDb();
  StreamSubscription<Aggregate>? _statsSub;
  List<Aggregate> _hourlyToday = [];
  List<Aggregate> _recentDaily = [];
  Aggregate? _todayDaily;
  late final String _deviceId;

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleService>();
    // DashboardScreen is only ever reached after a successful connect(),
    // so a device is always present here.
    _deviceId = ble.device!.remoteId.str;
    _statsSub = ble.statsUpdates.listen((agg) async {
      await _localDb.upsert(_deviceId, agg);
      await _reload();
    });
    _loadInitialStats(ble);
    _reload();
  }

  Future<void> _loadInitialStats(BleService ble) async {
    final initial = await ble.readCurrentStats();
    if (initial == null) return;
    await _localDb.upsert(_deviceId, initial);
    await _reload();
  }

  Future<void> _reload() async {
    final hourly = await _localDb.hourlyForDate(_deviceId, _todayString());
    final daily = await _localDb.recentDaily(_deviceId, limit: 14);
    final today = await _localDb.dailyForDate(_deviceId, _todayString());
    if (!mounted) return;
    setState(() {
      _hourlyToday = hourly;
      _recentDaily = daily;
      _todayDaily = today;
    });
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Prefer the daily "today so far" running total (from readCurrentStats()
    // on connect, or a daily rollover notification) over summing hourly
    // rows: the hourly breakdown only fills in as real hour-boundary
    // notifications arrive during a live connection, so it's frequently
    // empty even when the device already has a same-day total to show.
    final todayUnique = _todayDaily?.unique ??
        _hourlyToday.fold<int>(0, (sum, a) => sum + a.unique);
    final todayReturning = _todayDaily?.returning ??
        _hourlyToday.fold<int>(0, (sum, a) => sum + a.returning);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: _KpiCard(label: l10n.uniqueLabel, value: todayUnique),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _KpiCard(
                      label: l10n.returningLabel, value: todayReturning),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l10n.hourlyChartTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: _hourlyToday.isEmpty
                  ? Center(child: Text(l10n.noDataYet))
                  : _HourlyBarChart(data: _hourlyToday),
            ),
            const SizedBox(height: 24),
            Text(l10n.dailyChartTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: _recentDaily.isEmpty
                  ? Center(child: Text(l10n.noDataYet))
                  : _DailyBarChart(data: _recentDaily.reversed.toList()),
            ),
          ],
        ),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final int value;

  const _KpiCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('$value', style: Theme.of(context).textTheme.headlineMedium),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _HourlyBarChart extends StatelessWidget {
  final List<Aggregate> data;

  const _HourlyBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final byHour = {for (final a in data) a.hour!: a};
    final maxY = data
        .map((a) => a.unique)
        .fold<int>(1, (m, v) => v > m ? v : m)
        .toDouble();

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) => Text('${value.toInt()}'),
              interval: 4,
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 32),
          ),
        ),
        barGroups: List.generate(24, (hour) {
          final agg = byHour[hour];
          return BarChartGroupData(
            x: hour,
            barRods: [
              BarChartRodData(
                toY: (agg?.unique ?? 0).toDouble(),
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _DailyBarChart extends StatelessWidget {
  final List<Aggregate> data;

  const _DailyBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxY = data
        .map((a) => a.unique)
        .fold<int>(1, (m, v) => v > m ? v : m)
        .toDouble();

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= data.length) {
                  return const SizedBox.shrink();
                }
                final date = data[index].date;
                return Text(date.substring(5));
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 32),
          ),
        ),
        barGroups: List.generate(data.length, (i) {
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: data[i].unique.toDouble(),
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          );
        }),
      ),
    );
  }
}
