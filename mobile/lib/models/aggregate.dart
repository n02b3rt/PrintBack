/// Mirrors the BLE STATS JSON payload (docs/DATA_MODEL.md).
/// `hour == null` means a daily record (JSON `null`, not the firmware's
/// `-1` sentinel - a deliberate difference between the wire format and
/// the on-device struct, not a bug to "fix").
class Aggregate {
  final String date;
  final int? hour;
  final int unique;
  final int returning;
  final bool kanon;

  const Aggregate({
    required this.date,
    required this.hour,
    required this.unique,
    required this.returning,
    required this.kanon,
  });

  factory Aggregate.fromJson(Map<String, dynamic> json) {
    return Aggregate(
      date: json['date'] as String,
      hour: json['hour'] as int?,
      unique: json['unique'] as int,
      returning: json['returning'] as int,
      kanon: json['kanon'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'hour': hour,
      'unique': unique,
      'returning': returning,
      'kanon': kanon,
    };
  }

  /// The UTC instant this hourly record represents - only meaningful
  /// when [hour] is not null (a daily record has no single instant).
  /// The firmware has no RTC/timezone concept, everything on the wire
  /// ([date]/[hour]) is UTC (docs/DATA_MODEL.md) - this is the one
  /// place the phone's actual wall-clock timezone enters the picture.
  DateTime get utcInstant {
    final parts = date.split('-');
    return DateTime.utc(int.parse(parts[0]), int.parse(parts[1]),
        int.parse(parts[2]), hour ?? 0);
  }

  /// Wall-clock local hour (0-23) for an hourly record. Showing the raw
  /// UTC [hour] as e.g. "8:00" is wrong in any timezone other than
  /// UTC+0 - a Polish user in CEST (UTC+2) would see "8:00" for a
  /// record that actually happened at 10:00 their time.
  int get localHour => utcInstant.toLocal().hour;

  /// Local wall-clock calendar date (`YYYY-MM-DD`) for an hourly
  /// record - can differ from [date] (the UTC calendar date) for hours
  /// near local midnight, e.g. 00:30 CEST is still 22:30 UTC the
  /// previous day.
  String get localDate {
    final local = utcInstant.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
