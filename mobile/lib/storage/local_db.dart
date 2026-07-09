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

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            date TEXT NOT NULL,
            hour INTEGER,
            unique_count INTEGER NOT NULL,
            returning_count INTEGER NOT NULL,
            kanon_applied INTEGER NOT NULL,
            UNIQUE(date, hour)
          )
        ''');
      },
    );
    return _db!;
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
        'hour': agg.hour,
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
      where: 'date = ? AND hour IS NOT NULL',
      whereArgs: [date],
      orderBy: 'hour ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Daily rows (`hour IS NULL`), most recent first, capped at [limit].
  Future<List<Aggregate>> recentDaily({int limit = 30}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'hour IS NULL',
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
      where: 'date = ? AND hour IS NULL',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Aggregate _fromRow(Map<String, Object?> row) {
    return Aggregate(
      date: row['date'] as String,
      hour: row['hour'] as int?,
      unique: row['unique_count'] as int,
      returning: row['returning_count'] as int,
      kanon: (row['kanon_applied'] as int) != 0,
    );
  }
}
