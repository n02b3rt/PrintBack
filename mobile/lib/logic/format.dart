import 'package:intl/intl.dart';

/// Date/label formatting helpers, kept out of the widgets so both the
/// dashboard and statistics screens render dates the same human way
/// instead of the raw `YYYY-MM-DD` the firmware sends over the wire
/// (docs/DATA_MODEL.md). [locale] is the app's current language code
/// (e.g. 'pl'); `initializeDateFormatting()` must have run once at
/// startup for a non-English locale's month/day names to resolve.
String formatDayTitle(String isoDate, String locale) {
  final d = DateTime.parse(isoDate);
  return DateFormat('EEEE, d MMMM', locale).format(d);
}

/// Short axis form, e.g. `12.07` - locale-independent day.month.
String formatAxisDay(String isoDate) {
  final d = DateTime.parse(isoDate);
  return DateFormat('d.MM').format(d);
}

/// Whether to draw an x-axis label for point [index] of [count] points.
/// With few points every date fits, so show them all; past ~7 they smear
/// together, so show only the first, middle and last - a deterministic
/// pick rather than a modulo interval, which on a discrete axis skips one
/// date but keeps its neighbour (the "07-08, 07-10, 07-11" artefact, 10n).
bool showDayLabelAt(int index, int count) {
  if (count <= 7) return true;
  return index == 0 || index == count - 1 || index == (count - 1) ~/ 2;
}
