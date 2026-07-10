import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';

enum _Period { today, week, month, custom }

/// Business-owner-facing statistics, computed entirely from aggregates
/// already synced into the local db (docs/DECISIONS.md D3) - no new
/// per-client data, ever. Peak hour is best-effort: it only reflects
/// whatever hourly rows have accumulated from live notifications during
/// past connections (SYNC only backfills daily totals, see
/// docs/DATA_MODEL.md), so it gets more accurate the longer the app's
/// been used, not complete from day one.
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  final _localDb = LocalDb();
  _Period _period = _Period.week;
  DateTimeRange? _customRange;
  StreamSubscription<Aggregate>? _statsSub;

  List<Aggregate> _daily = [];
  List<Aggregate> _hourly = [];
  List<Aggregate> _prevDaily = [];

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleService>();
    _statsSub = ble.statsUpdates.listen((agg) async {
      await _localDb.upsert(_deviceId, agg);
      await _reload();
    });
    _reload();
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    super.dispose();
  }

  String get _deviceId => context.read<BleService>().device!.remoteId.str;

  DateTimeRange _rangeFor(_Period period) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (period) {
      case _Period.today:
        return DateTimeRange(start: today, end: today);
      case _Period.week:
        return DateTimeRange(
            start: today.subtract(const Duration(days: 6)), end: today);
      case _Period.month:
        return DateTimeRange(
            start: today.subtract(const Duration(days: 29)), end: today);
      case _Period.custom:
        return _customRange ?? DateTimeRange(start: today, end: today);
    }
  }

  Future<void> _reload() async {
    final range = _rangeFor(_period);
    final spanDays = range.end.difference(range.start).inDays + 1;
    final prevEnd = range.start.subtract(const Duration(days: 1));
    final prevStart = prevEnd.subtract(Duration(days: spanDays - 1));

    final daily =
        await _localDb.dailyInRange(_deviceId, _fmt(range.start), _fmt(range.end));
    final hourly = await _localDb.hourlyInRange(
        _deviceId, _fmt(range.start), _fmt(range.end));
    final prevDaily =
        await _localDb.dailyInRange(_deviceId, _fmt(prevStart), _fmt(prevEnd));

    if (!mounted) return;
    setState(() {
      _daily = daily;
      _hourly = hourly;
      _prevDaily = prevDaily;
    });
  }

  /// Garmin-Connect-style explicit "get me everything right now", same
  /// as Dashboard's sync button. Results arrive over statsUpdates, which
  /// this screen already listens to (see initState), so the numbers
  /// update on their own as replies come in.
  Future<void> _syncNow() async {
    final ble = context.read<BleService>();
    await ble.requestSync(0);
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _customRange,
    );
    if (picked == null) return;
    setState(() {
      _period = _Period.custom;
      _customRange = picked;
    });
    _reload();
  }

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  List<String> _weekdayLabels(AppLocalizations l10n) => [
        l10n.weekdayMon,
        l10n.weekdayTue,
        l10n.weekdayWed,
        l10n.weekdayThu,
        l10n.weekdayFri,
        l10n.weekdaySat,
        l10n.weekdaySun,
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final totalUnique = _daily.fold<int>(0, (s, a) => s + a.unique);
    final totalReturning = _daily.fold<int>(0, (s, a) => s + a.returning);
    final prevTotalUnique = _prevDaily.fold<int>(0, (s, a) => s + a.unique);
    final avgDaily = _daily.isEmpty ? 0 : (totalUnique / _daily.length).round();
    final returningRate =
        totalUnique == 0 ? 0 : (totalReturning * 100 / totalUnique).round();
    final delta = prevTotalUnique == 0
        ? null
        : ((totalUnique - prevTotalUnique) * 100 / prevTotalUnique).round();

    Aggregate? best;
    for (final a in _daily) {
      if (best == null || a.unique > best.unique) best = a;
    }

    final weekdaySums = List<int>.filled(7, 0);
    final weekdayCounts = List<int>.filled(7, 0);
    for (final a in _daily) {
      final parts = a.date.split('-');
      final d = DateTime.utc(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      final idx = d.weekday - 1;
      weekdaySums[idx] += a.unique;
      weekdayCounts[idx]++;
    }

    final hourSums = List<int>.filled(24, 0);
    final hourCounts = List<int>.filled(24, 0);
    for (final a in _hourly) {
      hourSums[a.hour!] += a.unique;
      hourCounts[a.hour!]++;
    }
    int? peakHour;
    double peakAvg = -1;
    for (var h = 0; h < 24; h++) {
      if (hourCounts[h] == 0) continue;
      final avg = hourSums[h] / hourCounts[h];
      if (avg > peakAvg) {
        peakAvg = avg;
        peakHour = h;
      }
    }

    final weekdayLabels = _weekdayLabels(l10n);
    final bestDayLabel = best == null
        ? '-'
        : weekdayLabels[DateTime.utc(
                  int.parse(best.date.split('-')[0]),
                  int.parse(best.date.split('-')[1]),
                  int.parse(best.date.split('-')[2]),
                ).weekday -
                1];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.statisticsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: l10n.syncNowButton,
            onPressed: _syncNow,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<_Period>(
              segments: [
                ButtonSegment(value: _Period.today, label: Text(l10n.periodToday)),
                ButtonSegment(value: _Period.week, label: Text(l10n.periodWeek)),
                ButtonSegment(value: _Period.month, label: Text(l10n.periodMonth)),
              ],
              selected: {_period == _Period.custom ? _Period.week : _period},
              onSelectionChanged: (s) {
                setState(() => _period = s.first);
                _reload();
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _pickCustomRange,
                icon: const Icon(Icons.date_range),
                label: Text(l10n.periodCustom),
              ),
            ),
            const SizedBox(height: 8),
            Text('$totalUnique', style: Theme.of(context).textTheme.headlineMedium),
            Text(l10n.totalUniqueLabel),
            if (delta != null)
              Text(
                '${delta >= 0 ? '+' : ''}$delta% ${l10n.vsPreviousPeriod}',
                style: TextStyle(
                  color: delta >= 0
                      ? Theme.of(context).colorScheme.tertiary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                      label: l10n.returningRateLabel, value: '$returningRate%'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child:
                      _StatCard(label: l10n.averageDailyLabel, value: '$avgDaily'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatCard(label: l10n.bestDayLabel, value: bestDayLabel),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    label: l10n.peakHourLabel,
                    value: peakHour != null ? '$peakHour:00' : '-',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l10n.weekdayPatternTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: _daily.isEmpty
                  ? Center(child: Text(l10n.noDataYet))
                  : _WeekdayChart(
                      sums: weekdaySums,
                      counts: weekdayCounts,
                      labels: weekdayLabels,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ),
    );
  }
}

class _WeekdayChart extends StatelessWidget {
  final List<int> sums;
  final List<int> counts;
  final List<String> labels;

  const _WeekdayChart({
    required this.sums,
    required this.counts,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final avgs =
        List.generate(7, (i) => counts[i] == 0 ? 0.0 : sums[i] / counts[i]);
    final maxY = avgs.fold<double>(1, (m, v) => v > m ? v : m);

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              if (group.x < 0 || group.x >= labels.length) return null;
              return BarTooltipItem(
                '${labels[group.x]}\n${avgs[group.x].round()}',
                const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                return Text(labels[i]);
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 32),
          ),
        ),
        barGroups: List.generate(
          7,
          (i) => BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: avgs[i],
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
