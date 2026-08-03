import 'dart:js_interop';

import 'package:flutter/foundation.dart';

@JS('window')
external _Window get _window;

extension type _Window._(JSObject _) implements JSObject {
  external double get innerHeight;
  external _VisualViewport? get visualViewport;
}

extension type _VisualViewport._(JSObject _) implements JSObject {
  external double get height;
  external double get offsetTop;
  external void addEventListener(String type, JSFunction listener);
}

final ValueNotifier<double> _inset = ValueNotifier<double>(0);
bool _wired = false;

/// Height of the window that the on-screen keyboard is sitting on top of.
///
/// `innerHeight` is the layout viewport and does not move when the keyboard
/// opens. `visualViewport` is what is actually on screen: it shrinks by the
/// keyboard's height, and `offsetTop` accounts for the browser having scrolled
/// within the layout viewport to reveal the focused field. Whatever is left
/// over is the part of the page hidden behind the keyboard.
///
/// Reads 0 when no keyboard is up, and on any browser without visualViewport,
/// so callers can add it unconditionally.
double _measure() {
  final viewport = _window.visualViewport;
  if (viewport == null) return 0;
  final hidden = _window.innerHeight - (viewport.height + viewport.offsetTop);
  // Small negative values show up mid-scroll; clamp rather than shift layout
  // upwards. The 1px floor keeps sub-pixel noise from triggering rebuilds.
  return hidden > 1 ? hidden : 0;
}

void _update() {
  final next = _measure();
  if ((next - _inset.value).abs() > 1) _inset.value = next;
}

ValueListenable<double> get keyboardInset {
  if (!_wired) {
    _wired = true;
    final viewport = _window.visualViewport;
    if (viewport != null) {
      void onViewportChange(JSAny _) => _update();
      // resize fires as the keyboard animates in and out; scroll fires when
      // the browser shifts the visual viewport to keep the caret visible.
      viewport.addEventListener('resize', onViewportChange.toJS);
      viewport.addEventListener('scroll', onViewportChange.toJS);
      _update();
    }
  }
  return _inset;
}

/// One-line readout for the on-device diagnostic overlay. There is no console
/// to read on a phone, and the whole question is what these numbers say when
/// the keyboard is up.
String keyboardInsetDebug() {
  final viewport = _window.visualViewport;
  if (viewport == null) return 'visualViewport: unsupported';
  return 'inner ${_window.innerHeight.toStringAsFixed(0)} · '
      'vv ${viewport.height.toStringAsFixed(0)} · '
      'top ${viewport.offsetTop.toStringAsFixed(0)} · '
      'hidden ${_measure().toStringAsFixed(0)}';
}
