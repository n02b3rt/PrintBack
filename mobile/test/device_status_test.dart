import 'package:flutter_test/flutter_test.dart';
import 'package:printback/models/device_status.dart';

void main() {
  test('parses a full STATUS payload', () {
    final s = DeviceStatus.fromJson({
      'fw': '5563585',
      'sd_ok': true,
      'sd_free_mb': 431,
      'uptime_s': 168,
      'heap': 115856,
      'reset': 'poweron',
    });
    expect(s.fw, '5563585');
    expect(s.sdOk, isTrue);
    expect(s.sdFreeMb, 431);
    expect(s.uptimeS, 168);
    expect(s.heap, 115856);
    expect(s.reset, 'poweron');
  });

  test('sd_ok false is carried through', () {
    expect(DeviceStatus.fromJson({'sd_ok': false}).sdOk, isFalse);
  });

  test('missing fields degrade to sensible defaults, no throw', () {
    final s = DeviceStatus.fromJson({});
    expect(s.fw, '?');
    expect(s.sdOk, isFalse);
    expect(s.sdFreeMb, 0);
    expect(s.reset, 'unknown');
  });
}
