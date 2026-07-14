import 'package:flutter_test/flutter_test.dart';
import 'package:printback/models/aggregate.dart';
import 'package:printback/storage/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Aggregate daily(String date, int unique, {int returning = 0, bool kanon = false}) =>
    Aggregate(date: date, hour: null, unique: unique, returning: returning, kanon: kanon);

Aggregate hourly(String date, int hour, int unique) =>
    Aggregate(date: date, hour: hour, unique: unique, returning: 0, kanon: false);

void main() {
  // Run the same schema on the desktop test VM (sqflite proper is
  // Android/iOS only). Each test gets a fresh on-disk database.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDb db;

  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
        '${await databaseFactory.getDatabasesPath()}/printback_aggregates.db');
    db = LocalDb();
  });

  tearDown(() async {
    await db.close();
  });

  const dev = 'AA:BB';
  const other = 'CC:DD';

  test('hasAnyData reflects presence', () async {
    expect(await db.hasAnyData(dev), isFalse);
    await db.upsert(dev, daily('2026-07-11', 5));
    expect(await db.hasAnyData(dev), isTrue);
    expect(await db.hasAnyData(other), isFalse);
  });

  test('daily upsert dedupes on (device, date)', () async {
    await db.upsert(dev, daily('2026-07-11', 5));
    await db.upsert(dev, daily('2026-07-11', 9)); // same day, resynced
    final rows = await db.recentDaily(dev);
    expect(rows.length, 1);
    expect(rows.first.unique, 9);
  });

  test('data is scoped per device', () async {
    await db.upsert(dev, daily('2026-07-11', 5));
    await db.upsert(other, daily('2026-07-11', 3));
    expect((await db.recentDaily(dev)).single.unique, 5);
    expect((await db.recentDaily(other)).single.unique, 3);
  });

  test('dailyInRange is inclusive and ordered', () async {
    await db.upsert(dev, daily('2026-07-10', 1));
    await db.upsert(dev, daily('2026-07-11', 2));
    await db.upsert(dev, daily('2026-07-12', 3));
    final rows = await db.dailyInRange(dev, '2026-07-10', '2026-07-11');
    expect(rows.map((a) => a.unique).toList(), [1, 2]);
  });

  test('hourly and daily rows do not collide', () async {
    await db.upsert(dev, daily('2026-07-11', 100));
    await db.upsert(dev, hourly('2026-07-11', 9, 4));
    expect((await db.recentDaily(dev)).single.unique, 100);
    expect((await db.hourlyForDate(dev, '2026-07-11')).single.unique, 4);
  });

  test('deleteDevice wipes only that device', () async {
    await db.upsert(dev, daily('2026-07-11', 5));
    await db.upsert(other, daily('2026-07-11', 3));
    await db.deleteDevice(dev);
    expect(await db.hasAnyData(dev), isFalse);
    expect(await db.hasAnyData(other), isTrue);
  });

  test('newestDailyDate returns the latest', () async {
    await db.upsert(dev, daily('2026-07-10', 1));
    await db.upsert(dev, daily('2026-07-12', 1));
    await db.upsert(dev, daily('2026-07-11', 1));
    expect(await db.newestDailyDate(dev), '2026-07-12');
  });

  test('v3 -> v4 upgrade preserves cached rows instead of dropping them',
      () async {
    // setUp already deleted the file and made a (lazy, unopened) LocalDb.
    // Create a v3 database by hand - the same schema an older app build
    // would have left on disk - with one synced day in it.
    final path =
        '${await databaseFactory.getDatabasesPath()}/printback_aggregates.db';
    final v3 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (d, v) => d.execute('''
          CREATE TABLE aggregates (
            device_id TEXT NOT NULL,
            date TEXT NOT NULL,
            hour INTEGER NOT NULL,
            unique_count INTEGER NOT NULL,
            returning_count INTEGER NOT NULL,
            kanon_applied INTEGER NOT NULL,
            UNIQUE(device_id, date, hour)
          )
        '''),
      ),
    );
    await v3.insert('aggregates', {
      'device_id': dev,
      'date': '2026-07-11',
      'hour': -1,
      'unique_count': 42,
      'returning_count': 7,
      'kanon_applied': 0,
    });
    await v3.close();

    // Opening through LocalDb (version 4) runs the v3->v4 migration.
    final upgraded = LocalDb();
    final rows = await upgraded.recentDaily(dev);
    expect(rows.single.unique, 42,
        reason: 'v3 cached data must survive the upgrade to v4');
    await upgraded.close();
  });
}
