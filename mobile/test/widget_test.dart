import 'package:flutter_test/flutter_test.dart';

import 'package:printback/main.dart';

void main() {
  testWidgets('app starts by trying to auto-connect', (WidgetTester tester) async {
    await tester.pumpWidget(const PrintBackApp());
    await tester.pump();

    // ConnectingScreen opens on the first auto-connect phase, looking for
    // an already-known device before falling back to a nearby scan.
    expect(find.text('Looking for known devices...'), findsOneWidget);
  });
}
