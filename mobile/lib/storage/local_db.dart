import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/aggregate.dart';

/// The app's ENTIRE local persistence surface. One table, four data
/// columns, all of them aggregate counts - zero MAC/fingerprint/per-client
/// fields, ever (.claude/rules/mobile-app.md, docs/DECISIONS.md D3). Never
/// add a column here that isn't already part of the BLE STATS payload in
/// docs/DATA_MODEL.md.
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
  /// A real integer sentinel makes the UNIQUE(date, hour) index work.
  static const _dayHour = -1;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: 2,
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
        date TEXT NOT NULL,
        hour INTEGER NOT NULL,
        unique_count INTEGER NOT NULL,
        returning_count INTEGER NOT NULL,
        kanon_applied INTEGER NOT NULL,
        UNIQUE(date, hour)
      )
    ''');
  }

  /// Upsert on (date, hour): a re-sent notification for a row already
  /// stored (e.g. a reconnect replaying unsynced history) overwrites the
  /// existing row instead of duplicating it.
  Future<void> upsert(Aggregate agg) async {
    final db = await _open();
    await db.insert(
      _table,
      {
        'date': agg.date,
        'hour': agg.hour ?? _dayHour,
        'unique_count': agg.unique,
        'returning_count': agg.returning,
        'kanon_applied': agg.kanon ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Hourly rows (`hour` 0-23) for one date, ordered by hour.
  Future<List<Aggregate>> hourlyForDate(String date) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'date = ? AND hour >= 0',
      whereArgs: [date],
      orderBy: 'hour ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Daily rows (`hour = -1`), most recent first, capped at [limit].
  Future<List<Aggregate>> recentDaily({int limit = 30}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'hour = ?',
      whereArgs: [_dayHour],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// The daily row for [date], if synced yet ("today so far").
  Future<Aggregate?> dailyForDate(String date) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'date = ? AND hour = ?',
      whereArgs: [date, _dayHour],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
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
