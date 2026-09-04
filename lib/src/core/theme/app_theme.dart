import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Mythos Palette — a bright, warm, romance-forward take on the app icon's
  // dusk-over-the-Aegean scene: white in place of the old purple field, a
  // rose primary carrying the interactive weight, antique gold for accents,
  // and the aegean purple demoted to a quiet secondary highlight.
  static const Color primaryColor = Color(0xFFC9487C); // Romantic Rose
  static const Color secondaryColor = Color(0xFFD4AF6A); // Warm Gold
  static const Color backgroundColor = Color(0xFFFFFFFF); // White
  static const Color surfaceColor = Color(0xFFFFF6F3); // Soft Blush White
  static const Color accentColor = Color(0xFF9B7EBD); // Aegean Lavender
  static const Color inkColor = Color(0xFF241D45); // Wordmark Navy-Plum
  static const Color mutedInkColor = Color(0xFF7A7288); // Muted body ink

  static ThemeData get romanticTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: backgroundColor,
      primaryColor: primaryColor,
      colorScheme: const ColorScheme.light(
        primary: primaryColor,
        secondary: secondaryColor,
        surface: surfaceColor,
        error: Colors.redAccent,
        onPrimary: Colors.white,
        onSecondary: inkColor,
        onSurface: inkColor,
      ),
      textTheme: TextTheme(
        displayLarge: GoogleFonts.playfairDisplay(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: inkColor,
        ),
        headlineSmall: GoogleFonts.playfairDisplay(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: inkColor,
        ),
        titleLarge: GoogleFonts.playfairDisplay(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: inkColor,
        ),
        titleMedium: GoogleFonts.playfairDisplay(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: inkColor,
        ),
        bodyLarge: GoogleFonts.lato(
          fontSize: 16,
          color: mutedInkColor,
        ),
        bodyMedium: GoogleFonts.lato(
          fontSize: 14,
          color: mutedInkColor,
        ),
        labelLarge: GoogleFonts.playfairDisplay(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: inkColor,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24), // Softer curves
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: primaryColor.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: primaryColor),
        ),
        hintStyle: GoogleFonts.lato(color: mutedInkColor.withOpacity(0.6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          textStyle: GoogleFonts.playfairDisplay(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30), // Pill shape
          ),
          elevation: 4,
          shadowColor: primaryColor.withOpacity(0.35),
        ),
      ),
      iconTheme: IconThemeData(color: inkColor.withOpacity(0.7)),
    );
  }
}
