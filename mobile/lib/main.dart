import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'ble/ble_service.dart';
import 'l10n/app_localizations.dart';
import 'onboarding/root_gate.dart';
import 'services/log_buffer.dart';
import 'services/weekly_notification.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Start capturing app logs into the in-memory ring buffer before anything
  // else runs, so a shake-triggered bug report has the whole session's
  // history. Nothing is persisted or transmitted by this - see
  // services/log_buffer.dart.
  LogBuffer.instance.install();
  // Load locale symbol data so intl's DateFormat can render Polish
  // (and any other supported locale's) weekday/month names, used by
  // lib/logic/format.dart.
  await initializeDateFormatting();
  await WeeklyNotification.instance.init();
  runApp(const PrintBackApp());
}

class PrintBackApp extends StatelessWidget {
  const PrintBackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) => MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeController.mode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RootGate(),
        ),
      ),
    );
  }
}
