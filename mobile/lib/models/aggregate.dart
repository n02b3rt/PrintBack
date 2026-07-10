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
}
