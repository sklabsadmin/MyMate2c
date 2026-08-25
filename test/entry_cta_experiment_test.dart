// The entry-cta experiment's one structural hazard: the experiment's name is
// written in three places that cannot import each other — the page script in
// web/index.html (which draws the arm and tags every funnel event), the
// template in tool/patch_splash.py (which REGENERATES that page script, so a
// name set only in index.html dies at the next splash rebuild), and
// AppConfig (which the entry card branches on). If any copy drifts, the page
// tags events with an experiment the app is not running, and the admin split
// reports a coin flip nobody's UI obeyed. These tests hold the copies
// together, and pin down what the arm parser treats as "hold the promise
// back".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_boyfriend_chat/src/core/config/app_config.dart';

/// The one line both page-script copies must carry.
String _experimentNamedIn(String path) {
  final source = File(path).readAsStringSync();
  final matches =
      RegExp(r"var EXPERIMENT = '([^']*)'").allMatches(source).toList();
  expect(matches, hasLength(1),
      reason: '$path must name the experiment exactly once');
  return matches.single.group(1)!;
}

void main() {
  test('the page, the splash template and the app run the same experiment',
      () {
    expect(_experimentNamedIn('web/index.html'), AppConfig.entryCtaExperiment,
        reason: 'the page is tagging events for a different experiment '
            'than the app is running');
    expect(_experimentNamedIn('tool/patch_splash.py'),
        AppConfig.entryCtaExperiment,
        reason: 'patch_splash.py regenerates the page script — a name set '
            'only in index.html reverts at the next splash rebuild');
  });

  test('only this experiment\'s arm b holds the coins promise back', () {
    final exp = AppConfig.entryCtaExperiment;
    expect(AppConfig.coinsPromiseHeldBack('$exp:b'), isTrue);
    expect(AppConfig.coinsPromiseHeldBack('$exp:a'), isFalse,
        reason: 'arm a is the coins card');
    expect(AppConfig.coinsPromiseHeldBack(null), isFalse,
        reason: 'no experiment running (or off the web, or an old cached '
            'index.html) means everyone gets the coins card');
    expect(AppConfig.coinsPromiseHeldBack(''), isFalse);
    expect(AppConfig.coinsPromiseHeldBack('some-other-exp:b'), isFalse,
        reason: 'a stale localStorage arm from a retired experiment must '
            'not keep holding the promise back');
    expect(AppConfig.coinsPromiseHeldBack('$exp:b:extra'), isFalse,
        reason: 'the match is exact, not a prefix');
  });

  test('the test override wins, and clearing it restores the wire value', () {
    AppConfig.debugVariantOverride = '${AppConfig.entryCtaExperiment}:b';
    addTearDown(() => AppConfig.debugVariantOverride = null);
    expect(AppConfig.coinsPromiseHeldBack(null), isTrue,
        reason: 'widget tests run off the web and depend on this knob');
    AppConfig.debugVariantOverride = null;
    expect(AppConfig.coinsPromiseHeldBack(null), isFalse);
  });
}
