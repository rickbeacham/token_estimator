import 'package:flutter/material.dart';

import 'ui/dashboard_screen.dart';

// Re-export core modules so existing imports of `main.dart` continue to work.
export 'data/catalog_repository.dart';
export 'engine/simulator.dart';
export 'engine/tokenizer.dart';
export 'pricing/model_pricing.dart';
export 'ui/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TokenEstimatorApp());
}

// ============================================================================
// APP ROOT & THEME
// ============================================================================

class TokenEstimatorApp extends StatelessWidget {
  const TokenEstimatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Token & Agent Loop Cost Simulator',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
          tertiary: Color(0xFFF59E0B),
          surface: Color(0xFF111827),
          onSurface: Color(0xFFF3F4F6),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111827),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF1F2937), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0B0F19),
          contentPadding: const EdgeInsets.all(14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF374151)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF1F2937)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
          ),
        ),
      ),
      home: const EstimatorDashboard(),
    );
  }
}