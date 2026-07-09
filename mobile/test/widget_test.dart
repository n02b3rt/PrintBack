import 'package:flutter_test/flutter_test.dart';

import 'package:printback/main.dart';

void main() {
  testWidgets('app starts on the pairing screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PrintBackApp());
    await tester.pump();

    expect(find.text('Pair device'), findsOneWidget);
  });
}
