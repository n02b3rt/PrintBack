import 'package:flutter_test/flutter_test.dart';

import 'package:printback/main.dart';

void main() {
  testWidgets('app starts by trying to auto-connect', (WidgetTester tester) async {
    await tester.pumpWidget(const PrintBackApp());
    await tester.pump();

    expect(find.text('Connecting to device...'), findsOneWidget);
  });
}
