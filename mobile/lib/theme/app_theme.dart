import 'package:flutter/material.dart';

/// Light and dark themes for PrintBack. Dark mode leans on near-black
/// surfaces with a restrained teal accent (deliberately not a broad
/// glassmorphism treatment - real backdrop blur on every card is
/// expensive on every scroll frame; the "glass" look here comes from
/// plain semi-transparent fills instead, same visual weight at zero
/// runtime cost). Light mode stays flat, no translucency at all.
class AppTheme {
  static const _teal = Color(0xFF2DD4BF);
  static const _tealDark = Color(0xFF0D9488);

  static final light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _tealDark,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFFAFAF8),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: Color(0xFFF1EFE8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFFAFAF8),
      foregroundColor: Color(0xFF1A1A1A),
      elevation: 0,
    ),
  );

  static final dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _teal,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF0A0D0D),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.09)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0A0D0D),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
  );
}
