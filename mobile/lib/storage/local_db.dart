import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/aggregate.dart';

/// The app's ENTIRE local persistence surface. One table, five columns
/// (four of them aggregate counts, one a device identifier) - zero
/// MAC/fingerprint/per-client fields, ever (.claude/rules/mobile-app.md,
/// docs/DECISIONS.md D3). Never add a column here that isn't already
/// part of the BLE STATS payload in docs/DATA_MODEL.md, or (for
/// `device_id`) needed to keep multiple paired devices' data from
/// mixing together.
///
/// Every query is scoped by `deviceId` (the BLE remoteId string) -
/// switching the active device in Settings must never show one
/// device's numbers under another's name.
class LocalDb {
  static const _dbName = 'printback_aggregates.db';
  static const _table = 'aggregates';

  Database? _db;

  /// Sentinel for a daily (whole-day) row, matching the on-device C
  /// struct's own convention (`hour_or_day: -1 = whole day`,
  /// firmware/main/sd_paths.h) - not just picked for consistency: SQLite's
  /// UNIQUE constraint treats every NULL as distinct from every other
  /// NULL, so a nullable `hour` column silently fails to deduplicate
  /// repeated daily-row upserts (each looked like a "new" unique key).
  /// A real integer sentinel makes the UNIQUE index actually work.
  static const _dayHour = -1;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) => _createTable(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('DROP TABLE IF EXISTS $_table');
        await _createTable(db);
      },
    );
    return _db!;
  }

  Future<void> _createTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_table (
        device_id TEXT NOT NULL,
        date TEXT NOT NULL,
        hour INTEGER NOT NULL,
        unique_count INTEGER NOT NULL,
        returning_count INTEGER NOT NULL,
        kanon_applied INTEGER NOT NULL,
        UNIQUE(device_id, date, hour)
      )
    ''');
  }

  /// Upsert on (device_id, date, hour): a re-sent notification for a row
  /// already stored (e.g. a sync replaying already-seen history)
  /// overwrites the existing row instead of duplicating it.
  Future<void> upsert(String deviceId, Aggregate agg) async {
    final db = await _open();
    await db.insert(
      _table,
      {
        'device_id': deviceId,
        'date': agg.date,
        'hour': agg.hour ?? _dayHour,
        'unique_count': agg.unique,
        'returning_count': agg.returning,
        'kanon_applied': agg.kanon ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Whether any row (hourly or daily) exists for this device - the gate
  /// for offline mode: if a previously-paired device has cached data,
  /// ConnectingScreen can drop straight into the dashboard without a live
  /// connection instead of forcing the pairing screen.
  Future<bool> hasAnyData(String deviceId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['1'],
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Deletes every row for one device - used when the user forgets a
  /// device and chooses to wipe its cached data from the phone too.
  Future<void> deleteDevice(String deviceId) async {
    final db = await _open();
    await db.delete(_table, where: 'device_id = ?', whereArgs: [deviceId]);
  }

  /// Hourly rows (`hour` 0-23) for one device and date, ordered by hour.
  Future<List<Aggregate>> hourlyForDate(String deviceId, String date) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'device_id = ? AND date = ? AND hour >= 0',
      whereArgs: [deviceId, date],
      orderBy: 'hour ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Daily rows (`hour = -1`) for one device, most recent first. No cap
  /// by default - aggregates are cheap (12 data bytes/row) and, per
  /// docs/DECISIONS.md D3, have no retention limit once synced to the
  /// phone, unlike the device's own 30-day raw-data SD retention.
  /// Callers that want a short window (e.g. a small "last N days" chart)
  /// pass [limit] explicitly.
  Future<List<Aggregate>> recentDaily(String deviceId, {int? limit}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'device_id = ? AND hour = ?',
      whereArgs: [deviceId, _dayHour],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// The daily row for one device and date, if synced yet ("today so far").
  Future<Aggregate?> dailyForDate(String deviceId, String date) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'device_id = ? AND date = ? AND hour = ?',
      whereArgs: [deviceId, date, _dayHour],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// The newest daily-row date already stored for this device, or null
  /// if nothing's synced yet. Used to compute a SYNC `since_unix_day`
  /// cutoff (docs/DATA_MODEL.md "BLE SYNC payload") without re-fetching
  /// history the phone already has.
  Future<String?> newestDailyDate(String deviceId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['date'],
      where: 'device_id = ? AND hour = ?',
      whereArgs: [deviceId, _dayHour],
      orderBy: 'date DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['date'] as String;
  }

  /// Daily rows (`hour = -1`) for one device within `[startDate, endDate]`
  /// (both `YYYY-MM-DD`, inclusive), oldest first. The building block for
  /// the statistics screen's period totals, deltas, and day-of-week
  /// pattern - all computed in Dart from this plain row list rather than
  /// in SQL, matching how the dashboard already computes its KPIs.
  Future<List<Aggregate>> dailyInRange(
    String deviceId,
    String startDate,
    String endDate,
  ) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'device_id = ? AND hour = ? AND date >= ? AND date <= ?',
      whereArgs: [deviceId, _dayHour, startDate, endDate],
      orderBy: 'date ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Hourly rows (`hour` 0-23) for one device within `[startDate, endDate]`
  /// - only ever as complete as what's arrived through live notifications
  /// during past connections, since SYNC only replays daily totals (see
  /// docs/DATA_MODEL.md "Backfill after a longer gap"). Used for a
  /// best-effort "peak hour" stat that improves as more data accumulates.
  Future<List<Aggregate>> hourlyInRange(
    String deviceId,
    String startDate,
    String endDate,
  ) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'device_id = ? AND hour >= 0 AND date >= ? AND date <= ?',
      whereArgs: [deviceId, startDate, endDate],
      orderBy: 'date ASC, hour ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Aggregate _fromRow(Map<String, Object?> row) {
    final hour = row['hour'] as int;
    return Aggregate(
      date: row['date'] as String,
      hour: hour == _dayHour ? null : hour,
      unique: row['unique_count'] as int,
      returning: row['returning_count'] as int,
      kanon: (row['kanon_applied'] as int) != 0,
    );
  }
}
