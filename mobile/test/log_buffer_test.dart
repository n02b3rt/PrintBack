import 'package:flutter_test/flutter_test.dart';
import 'package:printback/services/log_buffer.dart';

void main() {
  setUp(() => LogBuffer.instance.clear());

  group('scrub', () {
    test('masks the middle octets of a MAC address, keeping first and last',
        () {
      expect(LogBuffer.scrub('connected to AA:BB:CC:DD:EE:FF now'),
          'connected to AA:**:**:**:**:FF now');
    });

    test('masks lowercase and mixed-case addresses too', () {
      expect(LogBuffer.scrub('peer 3c:71:bf:0a:9e:40'),
          'peer 3c:**:**:**:**:40');
    });

    test('masks every address on a line, not just the first', () {
      expect(
        LogBuffer.scrub('A1:B2:C3:D4:E5:F6 -> 11:22:33:44:55:66'),
        'A1:**:**:**:**:F6 -> 11:**:**:**:**:66',
      );
    });

    test('leaves ordinary text and timestamps untouched', () {
      const line = 'sync done at 12:30:45, 14 rows, unique=6 returning=2';
      expect(LogBuffer.scrub(line), line);
    });
  });

  group('buffer', () {
    test('keeps lines and prefixes each with a timestamp', () {
      LogBuffer.instance.add('hello');
      expect(LogBuffer.instance.lines.single, endsWith('hello'));
      expect(LogBuffer.instance.lines.single, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\s')));
    });

    test('scrubs on the way in, so a MAC is never stored at all', () {
      LogBuffer.instance.add('bond with AA:BB:CC:DD:EE:FF');
      expect(LogBuffer.instance.lines.single, contains('AA:**:**:**:**:FF'));
      expect(LogBuffer.instance.lines.single, isNot(contains('BB:CC')));
    });

    test('splits a multi-line message into separate entries', () {
      LogBuffer.instance.add('first\nsecond');
      expect(LogBuffer.instance.lines.length, 2);
    });

    test('drops blank lines', () {
      LogBuffer.instance.add('a\n\n   \nb');
      expect(LogBuffer.instance.lines.length, 2);
    });

    test('caps at maxLines, dropping the oldest first', () {
      for (var i = 0; i < LogBuffer.maxLines + 50; i++) {
        LogBuffer.instance.add('line $i');
      }
      expect(LogBuffer.instance.lines.length, LogBuffer.maxLines);
      expect(LogBuffer.instance.lines.first, endsWith('line 50'));
      expect(LogBuffer.instance.lines.last,
          endsWith('line ${LogBuffer.maxLines + 49}'));
    });
  });
}
