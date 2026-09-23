import 'package:flutter/material.dart';

abstract final class AppTokens {
  static const pagePadding = 24.0;
  static const contentWidth = 480.0;
  static const sectionGap = 40.0;
  static const controlGap = 12.0;
  static const smallGap = 16.0;

  static const seedColor = Color(0xFFEF716C);
  static const surfaceColor = Color(0xFFFFFBF7);
  static const coral = Color(0xFFEF716C);
  static const ink = Color(0xFF211C1A);
  static const mutedInk = Color(0xFF736B68);
  static const lavender = Color(0xFFB9A0FF);
  static const paper = Color(0xFFFFF4E7);
}

ThemeData buildOtogurashiTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppTokens.seedColor,
    brightness: Brightness.light,
    surface: AppTokens.surfaceColor,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppTokens.surfaceColor,
    cardColor: Colors.white,
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w800,
        height: 1.18,
        letterSpacing: -0.8,
      ),
      headlineSmall: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
      titleMedium: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
      bodyLarge: TextStyle(height: 1.6),
      bodySmall: TextStyle(height: 1.5),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
      ),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
      ),
    ),
  );
}
