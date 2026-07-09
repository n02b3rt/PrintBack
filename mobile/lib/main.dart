import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ble/ble_service.dart';
import 'l10n/app_localizations.dart';
import 'screens/pairing_screen.dart';

void main() {
  runApp(const PrintBackApp());
}

class PrintBackApp extends StatelessWidget {
  const PrintBackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => BleService(),
      child: MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PairingScreen(),
      ),
    );
  }
}
