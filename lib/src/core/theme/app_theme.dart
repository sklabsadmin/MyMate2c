import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // The light-surface vocabulary. Every screen draws on white now, so these
  // replace the Colors.white / white.withOpacity(...) styling the dark theme
  // used: text that was white is ink, text that was white70/54 is mutedInk,
  // white38/24 hints are faintInk, translucent white fills are panel, and
  // white hairlines are hairline. Use these rather than ad-hoc opacities so
  // the app reads as one design.
  /// Hints, disabled labels, captions that may fade (≈ the old white38).
  static const Color faintInkColor = Color(0xFFA59FB2);

  /// Card and field fill on a white page (≈ the old white 0.05 fill).
  static const Color panelColor = Color(0xFFF7F3F6);

  /// Borders and dividers on a white page (≈ the old white 0.08 hairline).
  static const Color hairlineColor = Color(0xFFE8E2EA);

  /// Gold for TEXT on white. The accent gold (secondaryColor) is 2:1 against
  /// white and unreadable as a number or label; this is the same hue darkened
  /// to 5:1. Keep secondaryColor for fills, icons and borders, with ink on top.
  static const Color goldInkColor = Color(0xFF8C6A1F);

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
      // Dark status-bar text on every screen. Left to itself an AppBar picks
      // the style from its background, and the transparent bars (chat,
      // recents, create character) read as black — so iOS drew a white clock
      // and battery on a white page, i.e. none at all.
      appBarTheme: const AppBarTheme(
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        foregroundColor: inkColor,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}
