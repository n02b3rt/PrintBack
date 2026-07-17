import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../l10n/app_localizations.dart';
import '../logic/format.dart';
import '../logic/insights.dart';
import '../logic/opening_hours.dart';
import '../logic/stats_math.dart';
import '../models/aggregate.dart';
import '../onboarding/onboarding_flags.dart';
import '../onboarding/one_time_tip.dart';
import '../storage/local_db.dart';
import '../storage/opening_hours_store.dart';
import '../widgets/brand_mark.dart';
import '../widgets/chart_stats.dart';
import '../widgets/chart_style.dart';
import '../widgets/detail_sheet.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_background.dart';
import '../widgets/sync_status_banner.dart';
import 'chart_detail.dart';
import 'device_screen.dart';
import 'pairing_screen.dart';
import 'report_actions.dart';

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

  /// Switches the shell to the Statistics tab. The export lives there
  /// because it needs a period to export, which is that screen's whole job -
  /// the dashboard's quick action is a shortcut to it, not a second
  /// implementation of it.
  final VoidCallback? onOpenStatistics;

  const DashboardScreen({
    super.key,
    this.kpiKey,
    this.hourlyKey,
    this.bannerKey,
    this.onOpenStatistics,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _localDb = LocalDb();
  StreamSubscription<Aggregate>? _statsSub;
  Timer? _reloadDebounce;
  List<Aggregate> _hourlyToday = [];
  List<Aggregate> _recentDaily = [];
  Aggregate? _todayDaily;
  DayPace? _pace;
  OpeningHours _hours = OpeningHours.disabled;
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
    // BleService caches every incoming aggregate itself before emitting, so
    // this is purely a "something landed, redraw" signal.
    _statsSub = ble.statsUpdates.listen((_) => _scheduleReload());
    _loadInitialStats(ble);
    _loadHours();
    _reload();
  }

  /// Re-read on every mount rather than cached once: the operator can change
  /// the hours in Settings and come straight back to this tab.
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

  Future<void> _loadInitialStats(BleService ble) async {
    if (await ble.readCurrentStats() == null) return;
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

    // "Today vs a typical <weekday>" needs a longer baseline than the 14-day
    // chart above: 14 days only ever holds two same-weekdays. Ask for ~9
    // weeks so the average is over a handful of them, and take the intraday
    // shape from the last few days of hourly rows (that's as far back as the
    // device backfills hourly anyway, docs/DATA_MODEL.md). Both exclude
    // today - today can't be part of its own baseline.
    final paceDaily = await _localDb.recentDaily(_deviceId, limit: 63);
    final paceHourly = await _localDb.hourlyInRange(
      _deviceId,
      _dateString(now.subtract(const Duration(days: 9))),
      _dateString(now),
    );
    final pace = computeDayPace(
      pastDaily: paceDaily.where((a) => a.date != today).toList(),
      pastHourly: paceHourly.where((a) => a.localDate != today).toList(),
      todaySoFar: todayDaily?.unique ?? 0,
      todayWeekday: weekdayIndex(today),
      hour: now.hour,
    );

    if (!mounted) return;
    setState(() {
      _hourlyToday = hourly;
      // "Ostatnie dni" means the days that are done. Today is a running total
      // and it's already the three KPI cards and the hourly chart directly
      // above this chart - drawing it here too gave it a stunted bar that made
      // every afternoon look like a collapse, and dragged the strip's average
      // down with it. Same call as the install day (stats_math.withoutToday).
      _recentDaily = withoutToday(daily, today);
      _todayDaily = todayDaily;
      _pace = pace;
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
    _reloadDebounce?.cancel();
    _statsSub?.cancel();
    super.dispose();
  }

  List<String> _weekdayLabelsFull(AppLocalizations l10n) => [
        l10n.weekdayMonFull,
        l10n.weekdayTueFull,
        l10n.weekdayWedFull,
        l10n.weekdayThuFull,
        l10n.weekdayFriFull,
        l10n.weekdaySatFull,
        l10n.weekdaySunFull,
      ];

  List<String> _weekdayLabelsShort(AppLocalizations l10n) => [
        l10n.weekdayMon,
        l10n.weekdayTue,
        l10n.weekdayWed,
        l10n.weekdayThu,
        l10n.weekdayFri,
        l10n.weekdaySat,
        l10n.weekdaySun,
      ];

  /// Numbers for the hourly chart. Deliberately not the day's total - that's
  /// already the KPI right above, and repeating it would be filler. These say
  /// what the chart itself can't: when the rush was, how big a normal hour
  /// is, and how much of the day actually has data (which is what the gaps in
  /// the bars are, so the number explains them instead of leaving the
  /// operator to wonder).
  List<Widget> _hourlyStats(BuildContext context, AppLocalizations l10n) {
    final open = splitByOpening(_hourlyToday, _hours).open;
    if (open.isEmpty) return const [];

    final peak = open.reduce((a, b) => b.unique > a.unique ? b : a);
    final total = open.fold<int>(0, (s, a) => s + a.unique);
    final avg = (total / open.length).round();

    return [
      const Divider(height: 20),
      ChartStatStrip(stats: [
        (l10n.statPeak, '${peak.localHour}:00 · ${peak.unique}'),
        (l10n.statAvgHour, '$avg'),
        // Today's own weekday - the denominator is how long *this* day is
        // open, not some week-wide figure.
        (
          l10n.statHoursWithData,
          '${open.length}/${_hours.openHourCountOn(weekdayIndex(_todayString()))}'
        ),
      ]),
    ];
  }

  /// Numbers for the daily chart: the span's total, its best day and a
  /// typical day. Same rule as above - nothing here is already on screen.
  List<Widget> _dailyStats(BuildContext context, AppLocalizations l10n) {
    if (_recentDaily.isEmpty) return const [];
    final total = sumUnique(_recentDaily);
    final best = bestDay(_recentDaily);
    // Short weekday, not the full name: this cell gets a third of the row, and
    // "Czwartek · 198" doesn't fit in it - it ellipsised to "Czwartek · 1…",
    // dropping the number, which is the half worth reading. "Czw · 198" fits
    // and keeps both.
    final weekdays = _weekdayLabelsShort(l10n);
    return [
      const Divider(height: 20),
      ChartStatStrip(stats: [
        (l10n.statSum, '$total'),
        (
          l10n.statBest,
          best == null
              ? '-'
              : '${weekdays[weekdayIndex(best.date)]} · ${best.unique}'
        ),
        (l10n.statAvgDay, '${averagePerDay(total, _recentDaily.length)}'),
      ]),
    ];
  }

  /// Traffic outside opening hours, called out rather than hidden: it's real
  /// (deliveries, passers-by, the neighbour's flat) and quietly folding it
  /// into the day's total is what makes owners distrust the numbers. Only
  /// shown once the hours are configured and there's actually something out
  /// there.
  List<Widget> _afterHoursNote(BuildContext context, AppLocalizations l10n) {
    if (!_hours.enabled) return const [];
    final closed = splitByOpening(_hourlyToday, _hours).closed;
    final count = closed.fold<int>(0, (s, a) => s + a.unique);
    if (count <= 0) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(Icons.nightlight_outlined,
                size: 16, color: Theme.of(context).colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.afterHoursNote(count),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// Asks which period, then runs [action] with it. Both the report and the
  /// export cover a period, and which one is the operator's call - the panel
  /// has no business assuming "today".
  Future<void> _pickThen(BuildContext context, AppLocalizations l10n,
      Future<void> Function(QuickPeriod, DateTimeRange) action) async {
    final period = await pickQuickPeriod(context);
    if (period == null || !context.mounted) return;
    await action(period, quickRange(period));
  }

  /// The four things an owner actually reaches for, one tap from the panel
  /// instead of buried in tabs and app bars.
  Widget _quickActions(BuildContext context, AppLocalizations l10n) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _QuickAction(
          icon: Icons.ios_share,
          label: l10n.quickReport,
          onTap: () => _pickThen(context, l10n, (period, range) =>
              openReportForRange(context,
                  deviceId: _deviceId,
                  range: range,
                  periodLabel: quickPeriodLabel(l10n, period))),
        ),
        _QuickAction(
          icon: Icons.table_view,
          label: l10n.quickExport,
          // Actually exports. It used to just navigate to Statistics and
          // leave the operator to find the export button - the button dodging
          // the one question it needed to ask.
          onTap: () => _pickThen(context, l10n, (_, range) =>
              exportRangeToExcel(context,
                  deviceId: _deviceId,
                  range: range,
                  weekdaysFull: _weekdayLabelsFull(l10n))),
        ),
        _QuickAction(
          icon: Icons.developer_board,
          label: l10n.quickDevice,
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DeviceScreen())),
        ),
        _QuickAction(
          icon: Icons.bluetooth_searching,
          label: l10n.quickPairing,
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PairingScreen())),
        ),
      ],
    );
  }

  /// "Do 14:00 typowy wtorek ma około 40" + today's running total, with a
  /// verdict. Empty until [computeDayPace] has enough same-weekday history
  /// and enough hourly shape to place the current hour in the day - a guess
  /// dressed as a headline would be worse than no headline.
  List<Widget> _paceHero(BuildContext context, AppLocalizations l10n) {
    final pace = _pace;
    if (pace == null) return const [];
    final theme = Theme.of(context);

    final (String verdict, IconData icon, Color color) = switch (pace.verdict) {
      PaceVerdict.above => (
          l10n.paceAbove,
          Icons.trending_up,
          theme.colorScheme.primary
        ),
      PaceVerdict.below => (
          l10n.paceBelow,
          Icons.trending_down,
          theme.colorScheme.tertiary
        ),
      PaceVerdict.typical => (
          l10n.paceTypical,
          Icons.trending_flat,
          theme.colorScheme.outline
        ),
    };

    final weekdays = _weekdayLabelsFull(l10n);

    return [
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    verdict,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('${pace.soFar}',
                style: theme.textTheme.displaySmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              l10n.paceCaption(
                DateTime.now().hour,
                weekdays[weekdayIndex(_todayString())],
                pace.typicalByNow,
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _insightsSection(BuildContext context, AppLocalizations l10n) {
    // Exclude today's partial running total - insights compare complete days.
    // _recentDaily is already today-free (see _load) - the insights used to
    // filter it out here by hand, which is what made it obvious the rest of
    // the app should be doing the same thing.
    // Rotate on the day-of-year: more rules fire than fit on the card, so
    // the secondary slot cycles day to day instead of showing the same two
    // forever. Stable within a day, so the card doesn't reshuffle on every
    // rebuild/notification.
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year)).inDays;
    final insights = buildInsights(_recentDaily, rotationSeed: dayOfYear);
    if (insights.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    return [
      Text(l10n.insightsTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      GlassCard(
        child: Column(
          children: [
            for (var i = 0; i < insights.length; i++) ...[
              if (i > 0) const Divider(height: 20),
              Row(
                children: [
                  Icon(_insightIcon(insights[i].kind), color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_insightText(l10n, insights[i]))),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 24),
    ];
  }

  IconData _insightIcon(InsightKind kind) => switch (kind) {
        InsightKind.record => Icons.emoji_events,
        InsightKind.up => Icons.trending_up,
        InsightKind.down => Icons.trending_down,
        InsightKind.streak => Icons.local_fire_department,
        InsightKind.percentile => Icons.leaderboard,
        InsightKind.quiet => Icons.bedtime,
      };

  String _insightText(AppLocalizations l10n, Insight insight) =>
      switch (insight.kind) {
        InsightKind.record => l10n.insightRecord,
        InsightKind.up => l10n.insightUp(insight.percent),
        InsightKind.down => l10n.insightDown(insight.percent),
        InsightKind.streak => l10n.insightStreak(insight.count),
        InsightKind.percentile =>
          l10n.insightPercentile(insight.count, insight.total),
        InsightKind.quiet => l10n.insightQuiet,
      };

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
              const SizedBox(height: 8),
              _quickActions(context, l10n),
              const SizedBox(height: 16),
              // Hero: how today is going against a normal same-weekday at
              // this hour - the one question an owner has mid-shift. Hidden
              // until there's enough history to answer it honestly.
              ..._paceHero(context, l10n),
              // Insights: at most two plain-language takeaways about the
              // latest complete day (today's partial running total is
              // excluded so a half-day never reads as a "quiet" drop).
              ..._insightsSection(context, l10n),
              // IntrinsicHeight is what makes CrossAxisAlignment.stretch legal
              // here: this Row sits in a ListView, so its height is
              // unbounded, and stretch would hand the cards a tight infinite
              // height ("BoxConstraints forces an infinite height") and fail
              // to lay the panel out at all. IntrinsicHeight measures the
              // tallest card first and bounds the Row to it; the cost is one
              // extra layout pass over three cards.
              IntrinsicHeight(
                child: Row(
                  key: widget.kpiKey,
                  // Equal-height cards regardless of how the labels lay out.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child:
                          _KpiCard(label: l10n.uniqueLabel, value: todayUnique),
                    ),
                    const SizedBox(width: 12),
                    // "New" is unique minus returning, clamped at 0 - a real
                    // count of first-seen visitors, not the whole visitor
                    // total mislabelled as new (see docs/LEARNINGS.md 10k).
                    Expanded(
                      child: _KpiCard(
                          label: l10n.newVisitorsLabel,
                          value:
                              (todayUnique - todayReturning).clamp(0, todayUnique)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _KpiCard(
                          label: l10n.returningLabel, value: todayReturning),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Same pattern as the daily card below: a button, not a tap on
              // the chart. Tapping a bar already opens that hour's sheet, and
              // the drill-down is the rarer of the two.
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.hourlyChartTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChartDetail(
                            deviceId: _deviceId,
                            mode: ChartDetailMode.recent),
                      ),
                    ),
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: Text(l10n.expandChart),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GlassCard(
                key: widget.hourlyKey,
                child: Column(
                  children: [
                    SizedBox(
                      height: 200,
                      child: _hourlyToday.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(l10n.emptyHourlyHint,
                                    textAlign: TextAlign.center),
                              ),
                            )
                          : _HourlyBarChart(
                              data: _hourlyToday,
                              hours: _hours,
                              weekday: weekdayIndex(_todayString()),
                            ),
                    ),
                    ..._hourlyStats(context, l10n),
                  ],
                ),
              ),
              ..._afterHoursNote(context, l10n),
              const SizedBox(height: 24),
              // A separate affordance rather than a tap on the chart: tapping
              // a bar already opens that day's detail sheet, and stealing
              // that gesture for the drill-down would cost the more common
              // action to serve the rarer one.
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.dailyChartTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChartDetail(
                            deviceId: _deviceId,
                            mode: ChartDetailMode.trend),
                      ),
                    ),
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: Text(l10n.expandChart),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GlassCard(
                child: Column(
                  children: [
                    SizedBox(
                      height: 200,
                      child: _recentDaily.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  connected
                                      ? l10n.emptyNoData
                                      : l10n.emptyOffline,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : _DailyBarChart(data: _recentDaily.reversed.toList()),
                    ),
                    ..._dailyStats(context, l10n),
                  ],
                ),
              ),
              // Today is missing from the chart above on purpose - say so, or
              // the first question is "where's today?".
              if (_recentDaily.isNotEmpty) ...[
                const SizedBox(height: 8),
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
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _QuickAction({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 21, color: scheme.primary),
              ),
              const SizedBox(height: 6),
              Text(label,
                  style: Theme.of(context).textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
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
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$value', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          // Always one line. "Odwiedzający" is wider than a third of a phone
          // screen, and Flutter breaks an over-long single word mid-word
          // ("Odwiedzając" / "y") rather than hyphenating - which looked
          // broken and, because only this card wrapped, also made it taller
          // than its two neighbours. Scaling the label down keeps all three
          // identical and readable.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _HourlyBarChart extends StatelessWidget {
  final List<Aggregate> data;
  final OpeningHours hours;

  /// Which weekday these hours belong to (0=Monday). Opening hours are
  /// per-weekday, so "is this hour open" can't be answered without it.
  final int weekday;

  const _HourlyBarChart(
      {required this.data, required this.hours, required this.weekday});

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
      // Deliberately not a "share of today's traffic" percentage, which is
      // what used to sit here. There is no honest denominator for it: summing
      // the hourly counts double-counts anyone who came at 8 and again at 14,
      // so the hourly sum isn't the day's traffic - but the day's real total
      // (the KPI above) isn't the sum of these hours either, so any share
      // computed from it wouldn't add up to 100% across the day. Whichever we
      // picked, the number contradicted something already on screen: 43 at
      // 08:00 was labelled "18% of today" while the KPI said 111 visitors.
      // The same two counts the whole app speaks in say more and can't be
      // wrong, and the vs-average percentage lives in the interpretation
      // below, where it's a comparison rather than a fake part-of-whole.
      rows: [
        (l10n.newVisitorsLabel, '${(agg.unique - agg.returning).clamp(0, agg.unique)}'),
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

    // Peak among open hours only - a spike at 3am is not the shop's "busiest
    // hour" in any sense the operator means by the word.
    final peak = data
        .where((a) => hours.isOpenAt(weekday, a.localHour))
        .map((a) => a.unique)
        .fold<int>(0, (m, v) => v > m ? v : m);

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
          final closed = !hours.isOpenAt(weekday, hour);
          return BarChartGroupData(
            x: hour,
            barRods: [
              revolutRod(context, value,
                  // Never crown a closed hour the peak - "your busiest hour
                  // is 3am" is noise, not an insight.
                  highlight:
                      !closed && agg != null && agg.unique == peak && peak > 0,
                  muted: closed),
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
