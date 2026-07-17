import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/narrative.dart';
import '../logic/opening_hours.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../storage/local_db.dart';
import '../storage/opening_hours_store.dart';
import '../widgets/chart_style.dart';
import '../widgets/detail_sheet.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import 'chart_detail.dart';
import 'report_actions.dart';
import 'weekday_trend.dart';

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
  Timer? _reloadDebounce;
  OpeningHours _hours = OpeningHours.disabled;

  /// The day the device was switched on - a part-day that has to stay out of
  /// every average and baseline (lib/logic/stats_math.dart withoutInstallDay).
  String? _installDate;

  List<Aggregate> _daily = [];
  List<Aggregate> _hourly = [];
  List<Aggregate> _prevDaily = [];

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleService>();
    // BleService caches every incoming aggregate itself before emitting, so
    // this is purely a "something landed, redraw" signal.
    _statsSub = ble.statsUpdates.listen((_) => _scheduleReload());
    _loadHours();
    _reload();
  }

  Future<void> _loadHours() async {
    final h = await OpeningHoursStore.load();
    if (mounted) setState(() => _hours = h);
  }

  /// A SYNC backlog replay arrives as a burst of notifications; collapse it
  /// into one reload instead of re-querying the db once per row.
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), _reload);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _statsSub?.cancel();
    super.dispose();
  }

  // The active device id, not a live connection - the statistics screen
  // reads cached aggregates offline too (see BleService.activeDeviceId).
  String get _deviceId => context.read<BleService>().activeDeviceId!;

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
    // Firmware hourly rows are dated in UTC (no RTC on the device,
    // docs/DATA_MODEL.md); a 1-day pad on each side plus grouping by
    // Aggregate.localHour/localDate below covers hours that land on the
    // other side of the UTC/local day boundary (e.g. 00:30 CEST is
    // still 22:30 UTC the previous day).
    final hourly = await _localDb.hourlyInRange(
        _deviceId,
        _fmt(range.start.subtract(const Duration(days: 1))),
        _fmt(range.end.add(const Duration(days: 1))));
    // "Dziś" gets no baseline: a day that's twelve hours old against a
    // complete one isn't a comparison, it's a countdown to midnight that
    // reads as a collapse all afternoon. Same reason today stays out of
    // reports, and same call as the drill-down's today range.
    final prevDaily = _period == _Period.today
        ? const <Aggregate>[]
        : await _localDb.dailyInRange(_deviceId, _fmt(prevStart), _fmt(prevEnd));
    final installDate = await _localDb.oldestDailyDate(_deviceId);

    if (!mounted) return;
    setState(() {
      _installDate = installDate;
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

  /// The period in two or three plain sentences, above the numbers. Skipped
  /// for "today": a single in-progress day has no best day and nothing
  /// meaningful to compare against.
  List<Widget> _narrativeSection(BuildContext context, AppLocalizations l10n,
      List<String> weekdayLabelsFull) {
    if (_period == _Period.today) return const [];
    final n = buildPeriodNarrative(withoutInstallDay(_daily, _installDate),
        withoutInstallDay(_prevDaily, _installDate));
    if (n == null) return const [];

    final sentences = <String>[l10n.narrativeTotal(n.total)];
    if (n.bestDayWeekday != null && n.bestDayCount != null) {
      sentences.add(l10n.narrativeBestDay(
          weekdayLabelsFull[n.bestDayWeekday!], n.bestDayCount!));
    }
    final d = n.deltaPercent;
    if (d != null) {
      if (d >= 10) {
        sentences.add(l10n.narrativeUp(d));
      } else if (d <= -10) {
        sentences.add(l10n.narrativeDown(-d));
      } else {
        sentences.add(l10n.narrativeSteady);
      }
    }
    final rd = n.returningDeltaPoints;
    if (rd == null || rd.abs() < 3) {
      sentences.add(l10n.narrativeReturning(n.returningPct));
    } else if (rd > 0) {
      sentences.add(l10n.narrativeReturningUp(n.returningPct, rd));
    } else {
      sentences.add(l10n.narrativeReturningDown(n.returningPct, -rd));
    }

    return [
      Text(l10n.narrativeTitle,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      GlassCard(
        child: Text(
          sentences.join(' '),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
        ),
      ),
      const SizedBox(height: 24),
    ];
  }

  String _deltaPeople(AppLocalizations l10n, int diff) {
    if (diff == 0) return l10n.deltaPeopleSame;
    return diff > 0
        ? l10n.deltaPeopleMore(diff)
        : l10n.deltaPeopleFewer(-diff);
  }

  String _periodLabel(AppLocalizations l10n) {
    switch (_period) {
      case _Period.today:
        return l10n.periodToday;
      case _Period.week:
        return l10n.periodWeek;
      case _Period.month:
        return l10n.periodMonth;
      case _Period.custom:
        return l10n.periodCustom;
    }
  }

  bool _exporting = false;

  /// The period is already chosen on this screen, so no picker here - unlike
  /// the panel's quick action, which has to ask. Both end up in the same
  /// implementation (screens/report_actions.dart).
  /// What a report or an export actually covers, as opposed to what the screen
  /// is showing. Complete days only: today is still being collected, so
  /// including it reports a few hours of traffic as a day's total and drags
  /// the average down with it. Browsing today is fine and stays; filing it in
  /// a document is not. A custom range is left exactly as picked - those dates
  /// were an explicit choice, not a default we get to second-guess.
  (DateTimeRange, String) _reportScope(AppLocalizations l10n) =>
      switch (_period) {
        _Period.today => (
            quickRange(QuickPeriod.yesterday),
            l10n.periodYesterday
          ),
        _Period.week => (quickRange(QuickPeriod.week), l10n.periodWeek),
        _Period.month => (quickRange(QuickPeriod.month), l10n.periodMonth),
        _Period.custom => (_rangeFor(_period), _periodLabel(l10n)),
      };

  Future<void> _exportExcel(List<String> weekdaysFull) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final (range, _) = _reportScope(AppLocalizations.of(context)!);
      await exportRangeToExcel(context,
          deviceId: _deviceId, range: range, weekdaysFull: weekdaysFull);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _openReport(AppLocalizations l10n) {
    final (range, label) = _reportScope(l10n);
    openReportForRange(context,
        deviceId: _deviceId, range: range, periodLabel: label);
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

  // Full weekday names for the "best day" KPI tile, where a lone "Śr"
  // reads ambiguously as either "środa" or "średnia" (10l). Short labels
  // stay under the chart, where the week context disambiguates them.
  List<String> _weekdayLabelsFull(AppLocalizations l10n) => [
        l10n.weekdayMonFull,
        l10n.weekdayTueFull,
        l10n.weekdayWedFull,
        l10n.weekdayThuFull,
        l10n.weekdayFriFull,
        l10n.weekdaySatFull,
        l10n.weekdaySunFull,
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Everything on this screen is computed from complete days. The day the
    // device was switched on is half a day wearing a whole day's clothes -
    // left in, it drags the average under, flattens the trend line against
    // the floor, and skews whichever weekday it happens to land on. The
    // handful of visitors it drops are well inside the accuracy this product
    // already declares; the wrong average was not.
    //
    // Today is the same thing at the other end of the series, and was being
    // left in - so "Tydzień" was six days plus however much of this one had
    // happened by the time you looked. withoutToday's last-row guard makes
    // this a no-op for the "Dziś" period, where today is the entire subject.
    final today = _fmt(DateTime.now());
    final withoutFirst = withoutInstallDay(_daily, _installDate);
    final rows = withoutToday(withoutFirst, today);
    final prevRows = withoutInstallDay(_prevDaily, _installDate);
    // Kept apart: the two notes say different things, and one list length
    // can't tell you which end got trimmed.
    final excludedInstallDay = withoutFirst.length != _daily.length;
    final excludedToday = rows.length != withoutFirst.length;

    final totalUnique = sumUnique(rows);
    final totalReturning = sumReturning(rows);
    final prevTotalUnique = sumUnique(prevRows);
    final avgDaily = averagePerDay(totalUnique, rows.length);
    final returningRatePct = returningRate(totalUnique, totalReturning);
    final delta = deltaPercent(totalUnique, prevTotalUnique);
    final best = bestDay(rows);

    final weekdaySums = List<int>.filled(7, 0);
    final weekdayCounts = List<int>.filled(7, 0);
    for (final a in rows) {
      final idx = weekdayIndex(a.date);
      weekdaySums[idx] += a.unique;
      weekdayCounts[idx]++;
    }

    // _hourly was fetched with a 1-day UTC pad on each side (see
    // _reload()) to catch hours that land on the other side of the
    // UTC/local day boundary - the "Dziś" hourly chart needs only the
    // rows that actually fall on today's *local* calendar date.
    final todayLocal = _fmt(DateTime.now());
    final hourlyToday =
        _hourly.where((a) => a.localDate == todayLocal).toList();
    // Peak hour among open hours only: with the shop shut, "your busiest hour
    // is 4am" is a fact about the neighbourhood, not about the business.
    final peakHourValue = peakHour(splitByOpening(_hourly, _hours).open);

    final weekdayLabels = _weekdayLabels(l10n);
    final weekdayLabelsFull = _weekdayLabelsFull(l10n);
    final bestDayLabel =
        best == null ? '-' : weekdayLabelsFull[weekdayIndex(best.date)];
    final hourlyCoverageDays = daysWithHourlyData(_hourly);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.statisticsTitle),
        actions: [
          IconButton(
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.table_view),
            tooltip: l10n.exportButton,
            onPressed:
                _exporting ? null : () => _exportExcel(weekdayLabelsFull),
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: l10n.shareButton,
            onPressed: () => _openReport(l10n),
          ),
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
              SegmentedButton<_Period>(
                segments: [
                  ButtonSegment(
                      value: _Period.today, label: Text(l10n.periodToday)),
                  ButtonSegment(
                      value: _Period.week, label: Text(l10n.periodWeek)),
                  ButtonSegment(
                      value: _Period.month, label: Text(l10n.periodMonth)),
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
              // Said out loud rather than silently dropped: a day is missing
              // from these numbers and the operator is entitled to know which
              // and why.
              if (excludedToday) ...[
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(l10n.todayExcludedNote,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (excludedInstallDay) ...[
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(l10n.installDayExcluded,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              // The period in words, before the numbers - most owners want
              // the takeaway, not the table.
              ..._narrativeSection(context, l10n, weekdayLabelsFull),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$totalUnique',
                        style: Theme.of(context).textTheme.headlineMedium),
                    Text(l10n.totalUniqueLabel,
                        style: Theme.of(context).textTheme.bodySmall),
                    if (delta != null) ...[
                      const SizedBox(height: 4),
                      // A percentage tells you it moved; a headcount tells you
                      // what moved. "+15%" needs mental arithmetic against a
                      // number you'd have to go and find - "o 23 osoby więcej"
                      // is the thing itself. Both, because people scan for the
                      // percentage and then want to know what it means.
                      Text(
                        '${delta >= 0 ? '+' : ''}$delta% · '
                        '${_deltaPeople(l10n, totalUnique - prevTotalUnique)}',
                        style: TextStyle(
                          color: delta >= 0
                              ? Theme.of(context).colorScheme.tertiary
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Both rows are IntrinsicHeight + stretch so the two cards in a
              // row always match. Without it each card is only as tall as its
              // own text, and "Godzina szczytu" carries a two-line coverage
              // subtitle its neighbour doesn't - which left the grid visibly
              // ragged. (IntrinsicHeight is also what makes stretch legal at
              // all inside this ListView: unbounded height + stretch is a
              // layout error, not just ugly.)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _StatCard(
                          label: l10n.returningRateLabel,
                          value: '$returningRatePct%'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                          label: l10n.averageDailyLabel, value: '$avgDaily'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _StatCard(
                          label: l10n.bestDayLabel, value: bestDayLabel),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: l10n.peakHourLabel,
                        value: peakHourValue != null ? '$peakHourValue:00' : '-',
                        subtitle: peakHourValue != null
                            ? l10n.peakHourCoverage(hourlyCoverageDays)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              // A day-over-day trend needs more than one day, but "Dziś"
              // still has a real trend to show - just hourly instead of
              // daily. Either way: two lines (Nowi/Powracający), a line
              // chart rather than bars so it reads fine regardless of
              // point count (24 hours, 7 days, or 30) with no bar-width
              // cramping to manage.
              const SizedBox(height: 24),
              // Same affordance as the panel's daily chart, opening the same
              // drill-down - one screen for "look at this trend properly",
              // reachable from wherever the trend is on screen.
              Row(
                children: [
                  Expanded(
                    child: Text(
                        _period == _Period.today
                            ? l10n.hourlyChartTitle
                            : l10n.dailyTrendTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    // Expanding a chart should show more of what you tapped,
                    // not a different chart: "Dziś" draws hours here, so it
                    // opens the near-term drill-down (which starts on today);
                    // a week or a month is a trend question.
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChartDetail(
                          deviceId: _deviceId,
                          mode: _period == _Period.today
                              ? ChartDetailMode.recent
                              : ChartDetailMode.trend,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: Text(l10n.expandChart),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              revolutLegend(context, [
                (Theme.of(context).colorScheme.primary, l10n.uniqueLabel),
                (Theme.of(context).colorScheme.tertiary, l10n.returningLabel),
              ]),
              const SizedBox(height: 8),
              GlassCard(
                child: SizedBox(
                  height: 160,
                  child: _period == _Period.today
                      ? (hourlyToday.isEmpty
                          ? Center(child: Text(l10n.noDataYet))
                          : _HourlyTrendChart(
                              data: hourlyToday,
                              hours: _hours,
                              weekday: DateTime.now().weekday - 1))
                      : (_daily.isEmpty
                          ? Center(child: Text(l10n.noDataYet))
                          : _DailyTrendChart(data: rows)),
                ),
              ),
              // Same note as the drill-down: the shading has to explain itself
              // or it's just an unexplained grey box behind the line.
              if (_period == _Period.today && _hours.enabled) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.nightlight_outlined,
                        size: 14, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(l10n.closedHoursLegend,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.outline)),
                    ),
                  ],
                ),
              ],
              // A single "Dziś" day can only ever populate one weekday
              // bucket, so the 7-bar pattern chart is meaningless (six
              // empty bars, one real one) - hide it instead of showing
              // something that looks broken.
              if (_period != _Period.today) ...[
                const SizedBox(height: 24),
                Text(l10n.weekdayPatternTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                // Fewer than 7 days can't fill the weekday pattern - a
                // caption explains the empty bars so the chart doesn't
                // read as broken during a pilot's first week (10m).
                if (_daily.isNotEmpty && _daily.length < 7) ...[
                  const SizedBox(height: 4),
                  Text(l10n.weekdayPatternCoverage(_daily.length),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
                const SizedBox(height: 8),
                GlassCard(
                  child: SizedBox(
                    height: 160,
                    child: _daily.isEmpty
                        ? Center(child: Text(l10n.noDataYet))
                        : _WeekdayChart(
                            sums: weekdaySums,
                            counts: weekdayCounts,
                            labels: weekdayLabels,
                            fullLabels: weekdayLabelsFull,
                            deviceId: _deviceId,
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;

  const _StatCard({required this.label, required this.value, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _WeekdayChart extends StatelessWidget {
  final List<int> sums;
  final List<int> counts;
  final List<String> labels;

  /// Full weekday names and the device, so a tapped bar can offer the trend
  /// for that day - this chart averages the time dimension away, which is
  /// exactly what hides whether Tuesdays are climbing or sliding.
  final List<String> fullLabels;
  final String deviceId;

  const _WeekdayChart({
    required this.sums,
    required this.counts,
    required this.labels,
    required this.fullLabels,
    required this.deviceId,
  });

  void _showDetail(
      BuildContext context, AppLocalizations l10n, List<double> avgs, int i) {
    if (counts[i] == 0) return;
    final activeAvgs = [
      for (var d = 0; d < 7; d++)
        if (counts[d] > 0) avgs[d]
    ];
    final overallAvg =
        activeAvgs.isEmpty ? 0.0 : activeAvgs.reduce((a, b) => a + b) / activeAvgs.length;
    final maxAvg = activeAvgs.fold<double>(0, (m, v) => v > m ? v : m);
    final isBest = avgs[i] == maxAvg && maxAvg > 0;

    final trend = classifyTrend(avgs[i], overallAvg, isExtreme: isBest);
    final interpretation = switch (trend.cls) {
      TrendClass.extreme => l10n.interpretationBestDay,
      TrendClass.above => l10n.interpretationAboveAverage(trend.percent),
      TrendClass.below => l10n.interpretationBelowAverage(trend.percent),
      TrendClass.around => l10n.interpretationAroundAverage,
    };

    showDetailSheet(
      context,
      title: fullLabels[i],
      primaryValue: '~${avgs[i].round()}',
      primaryLabel: l10n.totalUniqueLabel,
      interpretation: interpretation,
      actionLabel: l10n.weekdayTrendTitle(fullLabels[i]),
      actionIcon: Icons.show_chart,
      onAction: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WeekdayTrend(
              deviceId: deviceId, weekday: i, weekdayName: fullLabels[i]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avgs =
        List.generate(7, (i) => counts[i] == 0 ? 0.0 : sums[i] / counts[i]);
    final maxY = avgs.fold<double>(1, (m, v) => v > m ? v : m);

    final l10n = AppLocalizations.of(context)!;
    final peak = avgs.fold<double>(0, (m, v) => v > m ? v : m);

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
            final index = response?.spot?.touchedBarGroupIndex;
            if (index == null) return;
            _showDetail(context, l10n, avgs, index);
          },
        ),
        titlesData: revolutTitles(
          context,
          bottomBuilder: (value, meta) {
            final i = value.toInt();
            if (i < 0 || i >= labels.length) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child:
                  Text(labels[i], style: Theme.of(context).textTheme.bodySmall),
            );
          },
        ),
        barGroups: List.generate(
          7,
          (i) => BarChartGroupData(
            x: i,
            barRods: [
              revolutRod(context, avgs[i], highlight: avgs[i] == peak && peak > 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailyTrendChart extends StatelessWidget {
  final List<Aggregate> data;

  const _DailyTrendChart({required this.data});

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
    // Breathing room at both ends. Without it the first and last points sit
    // exactly on the plot's edges, and their date labels - which fl_chart
    // centres on the point - hang off the sides of the card.
    final xSpan = (data.length - 1).toDouble();
    final xPad = xSpan <= 0 ? 0.5 : xSpan * 0.06;

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY * 1.2,
        minX: -xPad,
        maxX: xSpan + xPad,
        gridData: revolutGrid,
        borderData: revolutBorder,
        lineTouchData: LineTouchData(
          touchTooltipData: noLineTooltip,
          touchCallback: (event, response) {
            if (event is! FlTapUpEvent) return;
            final spot = response?.lineBarSpots?.firstOrNull;
            if (spot == null) return;
            _showDetail(context, l10n, spot.spotIndex);
          },
        ),
        titlesData: revolutTitles(
          context,
          // Integer step: without this fl_chart auto-picks a fractional
          // interval and renders the same date at several sub-integer x
          // positions, smearing the axis (the "12.0712.07..." bug).
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
        lineBarsData: revolutTwoLines(
          context,
          uniqueSpots: List.generate(
              data.length, (i) => FlSpot(i.toDouble(), data[i].unique.toDouble())),
          returningSpots: List.generate(data.length,
              (i) => FlSpot(i.toDouble(), data[i].returning.toDouble())),
        ),
      ),
    );
  }
}

class _HourlyTrendChart extends StatelessWidget {
  final List<Aggregate> data;

  /// Shades the hours the place is shut, so 3am traffic reads as "people walk
  /// past a closed shop" rather than as a fault. Same treatment as the
  /// drill-down's chart.
  final OpeningHours hours;

  /// Which weekday these hours belong to (0=Monday). Opening hours are
  /// per-weekday, so "is this hour open" can't be answered without it.
  final int weekday;

  const _HourlyTrendChart(
      {required this.data, required this.hours, required this.weekday});

  List<VerticalRangeAnnotation> _closedBands(Color color) {
    if (!hours.enabled) return const [];
    final out = <VerticalRangeAnnotation>[];
    int? runStart;
    for (var h = 0; h <= 24; h++) {
      final closed = h < 24 && !hours.isOpenAt(weekday, h);
      if (closed) {
        runStart ??= h;
      } else if (runStart != null) {
        out.add(VerticalRangeAnnotation(
            x1: runStart - 0.5, x2: h - 0.5, color: color));
        runStart = null;
      }
    }
    return out;
  }

  void _showDetail(BuildContext context, AppLocalizations l10n, Aggregate agg) {
    final hour = agg.localHour;
    final dayTotal = data.fold<int>(0, (s, a) => s + a.unique);
    final dayAvg = data.isEmpty ? 0.0 : dayTotal / data.length;
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
      // Same pair as the dashboard's hourly sheet - one hour should read the
      // same wherever you tap it.
      rows: [
        (l10n.newVisitorsLabel,
            '${(agg.unique - agg.returning).clamp(0, agg.unique)}'),
        (l10n.returningLabel, '${agg.returning}'),
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

    // Same reason as the daily trend: keep the end labels inside the card.
    final xPad = 24 * 0.06;

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY * 1.2,
        minX: -xPad,
        maxX: 23 + xPad,
        gridData: revolutGrid,
        borderData: revolutBorder,
        rangeAnnotations: RangeAnnotations(
          verticalRangeAnnotations: _closedBands(
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06)),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: noLineTooltip,
          touchCallback: (event, response) {
            if (event is! FlTapUpEvent) return;
            final spot = response?.lineBarSpots?.firstOrNull;
            if (spot == null) return;
            final agg = byHour[spot.spotIndex];
            if (agg == null) return;
            _showDetail(context, l10n, agg);
          },
        ),
        // Same declutter as the dashboard's hourly bar chart - 24 hour
        // numbers under the chart read as overlapping clutter, exact
        // hour lives in the tap-to-detail sheet's title instead.
        titlesData: revolutTitlesNone,
        lineBarsData: revolutTwoLines(
          context,
          uniqueSpots: List.generate(
              24, (h) => FlSpot(h.toDouble(), (byHour[h]?.unique ?? 0).toDouble())),
          returningSpots: List.generate(24,
              (h) => FlSpot(h.toDouble(), (byHour[h]?.returning ?? 0).toDouble())),
        ),
      ),
    );
  }
}
