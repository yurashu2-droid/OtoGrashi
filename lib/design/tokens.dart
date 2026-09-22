import 'package:flutter/material.dart';

abstract final class AppTokens {
  static const pagePadding = 24.0;
  static const contentWidth = 480.0;
  static const sectionGap = 40.0;
  static const controlGap = 12.0;
  static const smallGap = 16.0;

  static const seedColor = Color(0xFF356859);
  static const surfaceColor = Color(0xFFF8F5EF);
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
    scaffoldBackgroundColor: colorScheme.surface,
    textTheme: const TextTheme(
      displaySmall: TextStyle(fontWeight: FontWeight.w700, height: 1.25),
      bodyLarge: TextStyle(height: 1.6),
      bodySmall: TextStyle(height: 1.5),
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
