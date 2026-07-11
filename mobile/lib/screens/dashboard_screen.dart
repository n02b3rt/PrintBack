import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import '../widgets/brand_mark.dart';
import '../widgets/chart_style.dart';
import '../widgets/detail_sheet.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import '../widgets/sync_status_banner.dart';

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

  /// Garmin-Connect-style explicit "get me everything right now", as
  /// opposed to HomeShell's automatic sync-since-last-time on connect.
  /// Results still arrive over statsUpdates, not a return value here.
  Future<void> _syncNow() async {
    final ble = context.read<BleService>();
    await ble.requestSync(0);
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
        title: BrandMark(label: l10n.dashboardTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: l10n.syncNowButton,
            onPressed: _syncNow,
          ),
        ],
      ),
      body: GradientBackground(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SyncStatusBanner(),
              const SizedBox(height: 16),
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
              GlassCard(
                child: SizedBox(
                  height: 200,
                  child: _hourlyToday.isEmpty
                      ? Center(child: Text(l10n.noDataYet))
                      : _HourlyBarChart(data: _hourlyToday),
                ),
              ),
              const SizedBox(height: 24),
              Text(l10n.dailyChartTitle,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              GlassCard(
                child: SizedBox(
                  height: 200,
                  child: _recentDaily.isEmpty
                      ? Center(child: Text(l10n.noDataYet))
                      : _DailyBarChart(data: _recentDaily.reversed.toList()),
                ),
              ),
            ],
          ),
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
    return GlassCard(
      child: Column(
        children: [
          Text('$value', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _HourlyBarChart extends StatelessWidget {
  final List<Aggregate> data;

  const _HourlyBarChart({required this.data});

  void _showDetail(BuildContext context, AppLocalizations l10n, Aggregate agg) {
    final hour = agg.hour!;
    final dayTotal = data.fold<int>(0, (s, a) => s + a.unique);
    final dayAvg = data.isEmpty ? 0.0 : dayTotal / data.length;
    final share = dayTotal == 0 ? 0 : (agg.unique * 100 / dayTotal).round();
    final isPeak =
        agg.unique == data.map((a) => a.unique).reduce((a, b) => a > b ? a : b) &&
            agg.unique > 0;

    String interpretation;
    if (isPeak) {
      interpretation = l10n.interpretationPeakHour;
    } else if (dayAvg > 0 && agg.unique > dayAvg * 1.2) {
      interpretation = l10n.interpretationAboveAverage(
          ((agg.unique / dayAvg - 1) * 100).round());
    } else if (dayAvg > 0 && agg.unique < dayAvg * 0.8) {
      interpretation = l10n.interpretationBelowAverage(
          ((1 - agg.unique / dayAvg) * 100).round());
    } else {
      interpretation = l10n.interpretationAroundAverage;
    }

    showDetailSheet(
      context,
      title: '${hour.toString().padLeft(2, '0')}:00',
      primaryValue: '${agg.unique}',
      primaryLabel: l10n.uniqueLabel,
      rows: [
        (l10n.returningLabel, '${agg.returning}'),
        (l10n.shareOfDayLabel, '$share%'),
      ],
      interpretation: interpretation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final byHour = {for (final a in data) a.hour!: a};
    final maxY = data
        .map((a) => a.unique)
        .fold<int>(1, (m, v) => v > m ? v : m)
        .toDouble();

    final peak = data.map((a) => a.unique).fold<int>(0, (m, v) => v > m ? v : m);

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        gridData: revolutGrid,
        borderData: revolutBorder,
        barTouchData: BarTouchData(
          touchCallback: (event, response) {
            // fl_chart fires both FlPanDownEvent and FlTapDownEvent for a
            // single tap on Android (isInterestedForInteractions is true
            // for both), so gating on that alone opened two stacked
            // detail sheets per tap - FlTapUpEvent fires exactly once.
            if (event is! FlTapUpEvent) return;
            final hour = response?.spot?.touchedBarGroupIndex;
            final agg = hour == null ? null : byHour[hour];
            if (agg == null) return;
            _showDetail(context, l10n, agg);
          },
        ),
        // 24 hour numbers crammed under the bars read as clutter/overlap
        // (confirmed on hardware) regardless of thinning - dropped
        // entirely, matching the already-hidden y-axis: exact hour lives
        // in the tap-to-detail sheet's title instead.
        titlesData: revolutTitlesNone,
        barGroups: List.generate(24, (hour) {
          final agg = byHour[hour];
          final value = (agg?.unique ?? 0).toDouble();
          return BarChartGroupData(
            x: hour,
            barRods: [
              revolutRod(context, value, highlight: agg != null && agg.unique == peak && peak > 0),
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

  void _showDetail(BuildContext context, AppLocalizations l10n, int index) {
    if (index < 0 || index >= data.length) return;
    final agg = data[index];
    final total = data.fold<int>(0, (s, a) => s + a.unique);
    final avg = data.isEmpty ? 0.0 : total / data.length;
    final maxUnique = data.map((a) => a.unique).reduce((a, b) => a > b ? a : b);
    final isBest = agg.unique == maxUnique && agg.unique > 0;

    String interpretation;
    if (isBest) {
      interpretation = l10n.interpretationBestDay;
    } else if (avg > 0 && agg.unique > avg * 1.2) {
      interpretation =
          l10n.interpretationAboveAverage(((agg.unique / avg - 1) * 100).round());
    } else if (avg > 0 && agg.unique < avg * 0.8) {
      interpretation = l10n.interpretationBelowAverage(
          ((1 - agg.unique / avg) * 100).round());
    } else {
      interpretation = l10n.interpretationAroundAverage;
    }

    showDetailSheet(
      context,
      title: agg.date,
      primaryValue: '${agg.unique}',
      primaryLabel: l10n.uniqueLabel,
      rows: [
        (l10n.returningLabel, '${agg.returning}'),
        if (agg.kanon) (l10n.kanonBadge, ''),
      ],
      interpretation: interpretation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final maxY = data
        .map((a) => a.unique)
        .fold<int>(1, (m, v) => v > m ? v : m)
        .toDouble();
    // Cap visible x-axis labels regardless of how many days are shown -
    // one label per bar overlaps into an unreadable smear once there are
    // more than ~6-7 bars in a card-width chart.
    final labelInterval = (data.length / 6).ceil().clamp(1, data.length);

    final peak = data.map((a) => a.unique).fold<int>(0, (m, v) => v > m ? v : m);

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        gridData: revolutGrid,
        borderData: revolutBorder,
        barTouchData: BarTouchData(
          touchCallback: (event, response) {
            // See the hourly chart's touchCallback above for why this
            // checks FlTapUpEvent specifically instead of
            // isInterestedForInteractions.
            if (event is! FlTapUpEvent) return;
            final index = response?.spot?.touchedBarGroupIndex;
            if (index == null) return;
            _showDetail(context, l10n, index);
          },
        ),
        titlesData: revolutTitles(
          context,
          bottomInterval: labelInterval.toDouble(),
          bottomBuilder: (value, meta) {
            final index = value.toInt();
            if (index < 0 || index >= data.length) return const SizedBox.shrink();
            if (index % labelInterval != 0) return const SizedBox.shrink();
            final date = data[index].date;
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(date.substring(5),
                  style: Theme.of(context).textTheme.bodySmall),
            );
          },
        ),
        barGroups: List.generate(data.length, (i) {
          return BarChartGroupData(
            x: i,
            barRods: [
              revolutRod(context, data[i].unique.toDouble(),
                  highlight: data[i].unique == peak && peak > 0),
            ],
          );
        }),
      ),
    );
  }
}
