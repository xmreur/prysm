import 'package:flutter/material.dart';

class ThemeManager {
  static ThemeData getTheme(int themeIndex) {
    switch (themeIndex) {
      case 0: // Light Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.light
          ),
          scaffoldBackgroundColor: const Color(0xFFF5F5F5),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            elevation: 0,
            centerTitle: false,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          cardTheme: const CardThemeData(color: Colors.white),
        );
      case 1: // Dark Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF121212),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1E1E1E),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardColor: const Color(0xFF1E1E1E),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF2A2A2A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      case 2: // Pink Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.pink,
            brightness: Brightness.dark
          ),
          scaffoldBackgroundColor: const Color(0xFF1A1218),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF261820),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardColor: const Color(0xFF261820),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF2E1E28),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      case 3: // Cyan Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.cyan,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0E1519),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF152025),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardColor: const Color(0xFF152025),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF1A2830),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      case 4: // Purple Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.purple,
            brightness: Brightness.dark
          ),
          scaffoldBackgroundColor: const Color(0xFF14121E),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1C1830),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardColor: const Color(0xFF1C1830),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF241E38),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      case 5: // Orange Mode
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.orange,
            brightness: Brightness.dark
          ),
          scaffoldBackgroundColor: const Color(0xFF1A1410),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF2A2018),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          cardColor: const Color(0xFF2A2018),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF342818),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      default:
        return ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        );
    }
  }
}