import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:printback/main.dart';

void main() {
  testWidgets('first run opens the welcome carousel', (WidgetTester tester) async {
    // Fresh install: no onboarding flag set, so the root gate shows the
    // welcome carousel before the normal connect flow.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PrintBackApp());
    // Explicit pumps, not pumpAndSettle: the device illustration on card 2
    // runs a repeating LED animation that never "settles". Two frames is
    // enough to resolve the root gate's prefs FutureBuilder.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('See the footfall in your place'), findsOneWidget);
  });
}
