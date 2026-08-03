import 'package:flutter/foundation.dart';

/// Non-web builds: Flutter already reports the keyboard through
/// MediaQuery.viewInsets, so there is nothing to correct and this stays 0.
final ValueListenable<double> keyboardInset = ValueNotifier<double>(0);

/// Diagnostic readout, empty off the web.
String keyboardInsetDebug() => '';
