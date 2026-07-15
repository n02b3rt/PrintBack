import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../onboarding/onboarding_flags.dart';
import '../onboarding/one_time_tip.dart';
import '../storage/local_db.dart';
import '../widgets/brand_mark.dart';
import '../widgets/chart_style.dart';
import '../widgets/detail_sheet.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import '../widgets/sync_status_banner.dart';
import 'device_screen.dart';

/// Today's date as `YYYY-MM-DD`, matching docs/DATA_MODEL.md's STATS
/// `date` field format.
String _todayString() => _dateString(DateTime.now());

String _dateString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class DashboardScreen extends StatefulWidget {
  /// Optional keys the onboarding coach marks (11d) attach to the KPI row,
  /// the hourly chart and the status banner, so the first-run tour can
  /// spotlight each. Null in normal use.
  final GlobalKey? kpiKey;
  final GlobalKey? hourlyKey;
  final GlobalKey? bannerKey;

  const DashboardScreen({
    super.key,
    this.kpiKey,
    this.hourlyKey,
    this.bannerKey,
  });

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
    // Keyed by the active device id, not a live connection: the dashboard
    // is reached either after a successful connect() or (offline mode)
    // when cached data exists for a previously-paired device, so
    // activeDeviceId is always set by the time this screen mounts, but
    // ble.device may be null (offline).
    _deviceId = ble.activeDeviceId!;
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
    // Firmware records are dated/houred in UTC (no RTC on the device,
    // docs/DATA_MODEL.md); "today" for the hourly chart means the
    // phone's *local* calendar day, which can span two adjacent UTC
    // dates near local midnight (e.g. 00:30 CEST is still 22:30 UTC the
    // previous day). Query a 1-day pad on each side and filter/group by
    // Aggregate.localDate/localHour below rather than the raw UTC
    // fields, so an hour near the boundary lands on the right side.
    final now = DateTime.now();
    final hourlyPadded = await _localDb.hourlyInRange(
      _deviceId,
      _dateString(now.subtract(const Duration(days: 1))),
      _dateString(now.add(const Duration(days: 1))),
    );
    final today = _todayString();
    final hourly = hourlyPadded.where((a) => a.localDate == today).toList();
    final daily = await _localDb.recentDaily(_deviceId, limit: 14);
    final todayDaily = await _localDb.dailyForDate(_deviceId, today);
    if (!mounted) return;
    setState(() {
      _hourlyToday = hourly;
      _recentDaily = daily;
      _todayDaily = todayDaily;
    });
    _maybeShowKanonTip();
  }

  bool _kanonTipShown = false;

  /// First time a k-anonymity-collapsed day actually shows up, explain the
  /// badge once (report 3.6). Only after the coach-mark tour, so tips don't
  /// stack on the first run.
  Future<void> _maybeShowKanonTip() async {
    if (_kanonTipShown || !_recentDaily.any((a) => a.kanon)) return;
    _kanonTipShown = true;
    if (!await OnboardingFlags.coachMarksDone()) return;
    if (await OnboardingFlags.kanonTipSeen()) return;
    await OnboardingFlags.setKanonTipSeen();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showOneTimeTip(context,
        title: l10n.tipKanonTitle, body: l10n.tipKanonBody);
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The sync icon needs a fully-ready connection; offline (or mid-attempt
    // on a wrong device) it's disabled - the status banner carries the
    // [Connect] affordance instead.
    final connected = context.watch<BleService>().isConnectedReady;
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
            icon: const Icon(Icons.developer_board),
            tooltip: l10n.deviceScreenTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DeviceScreen()),
            ),
          ),
        ],
      ),
      body: GradientBackground(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SyncStatusBanner(key: widget.bannerKey),
              const SizedBox(height: 16),
              Row(
                key: widget.kpiKey,
                children: [
                  Expanded(
                    child: _KpiCard(label: l10n.uniqueLabel, value: todayUnique),
                  ),
                  const SizedBox(width: 12),
                  // "New" is unique minus returning, clamped at 0 - a real
                  // count of first-seen visitors, not the whole visitor
                  // total mislabelled as new (see docs/LEARNINGS.md 10k).
                  Expanded(
                    child: _KpiCard(
                        label: l10n.newVisitorsLabel,
                        value: (todayUnique - todayReturning).clamp(0, todayUnique)),
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
                key: widget.hourlyKey,
                child: SizedBox(
                  height: 200,
                  child: _hourlyToday.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(l10n.emptyHourlyHint,
                                textAlign: TextAlign.center),
                          ),
                        )
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
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              connected ? l10n.emptyNoData : l10n.emptyOffline,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
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
    final hour = agg.localHour;
    final dayTotal = data.fold<int>(0, (s, a) => s + a.unique);
    final dayAvg = data.isEmpty ? 0.0 : dayTotal / data.length;
    final share = dayTotal == 0 ? 0 : (agg.unique * 100 / dayTotal).round();
    final isPeak =
        agg.unique == data.map((a) => a.unique).reduce((a, b) => a > b ? a : b) &&
            agg.unique > 0;

    final trend = classifyTrend(agg.unique, dayAvg, isExtreme: isPeak);
    final interpretation = switch (trend.cls) {
      TrendClass.extreme => l10n.interpretationPeakHour,
      TrendClass.above => l10n.interpretationAboveAverage(trend.percent),
      TrendClass.below => l10n.interpretationBelowAverage(trend.percent),
      TrendClass.around => l10n.interpretationAroundAverage,
    };

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
    // Keyed by local hour, not the raw UTC hour on the wire - see
    // Aggregate.localHour.
    final byHour = {for (final a in data) a.localHour: a};
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
          touchTooltipData: noBarTooltip,
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
        // Sparse anchors at 0/6/12/18 give the day a readable frame
        // (morning/noon/evening) without 24 crammed numbers; the exact
        // hour still lives in the tap-to-detail sheet's title.
        titlesData: revolutTitlesSparseHours(context),
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

    final trend = classifyTrend(agg.unique, avg, isExtreme: isBest);
    final interpretation = switch (trend.cls) {
      TrendClass.extreme => l10n.interpretationBestDay,
      TrendClass.above => l10n.interpretationAboveAverage(trend.percent),
      TrendClass.below => l10n.interpretationBelowAverage(trend.percent),
      TrendClass.around => l10n.interpretationAroundAverage,
    };

    showDetailSheet(
      context,
      title: formatDayTitle(agg.date, Localizations.localeOf(context).languageCode),
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

    final peak = data.map((a) => a.unique).fold<int>(0, (m, v) => v > m ? v : m);

    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        gridData: revolutGrid,
        borderData: revolutBorder,
        barTouchData: BarTouchData(
          touchTooltipData: noBarTooltip,
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
          bottomInterval: 1,
          bottomBuilder: (value, meta) {
            final index = value.toInt();
            if (index < 0 || index >= data.length) return const SizedBox.shrink();
            if (value != index.toDouble()) return const SizedBox.shrink();
            if (!showDayLabelAt(index, data.length)) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(formatAxisDay(data[index].date),
                  style: Theme.of(context).textTheme.bodySmall),
            );
          },
        ),
        // Reserve at least 7 slots so a 2-day-old install shows two
        // normal-width bars in a stable frame, not two giant bars filling
        // the card (10m). Extra slots past the real data are empty.
        barGroups: List.generate(data.length < 7 ? 7 : data.length, (i) {
          final value = i < data.length ? data[i].unique.toDouble() : 0.0;
          return BarChartGroupData(
            x: i,
            barRods: [
              revolutRod(context, value,
                  highlight: i < data.length &&
                      data[i].unique == peak &&
                      peak > 0),
            ],
          );
        }),
      ),
    );
  }
}
