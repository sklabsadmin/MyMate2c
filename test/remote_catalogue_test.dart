// The remote catalogue: characters and gifts the worker adds or changes
// without an app release (lib/src/core/data/remote_catalogue.dart; the
// worker half is backend/src/catalogue.js and backend/test/catalogue.test.mjs).
//
// The promise under test is twofold. With no catalogue, the app is exactly
// the build: same roster, same order, same gifts. With one, additions and
// rewrites show up through the SAME names the screens already read
// (kCharacters, characterById, profileForCharacter, kTributeOptions), and
// nothing a worker can send — a half-written entry, a newer schema, junk —
// takes a screen down.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/config/app_config.dart';
import 'package:mythos_live/src/core/data/character_nudges.dart';
import 'package:mythos_live/src/core/data/character_profiles.dart';
import 'package:mythos_live/src/core/data/characters.dart';
import 'package:mythos_live/src/core/data/remote_catalogue.dart';
import 'package:mythos_live/src/features/wallet/presentation/coins_sheet.dart';

/// What GET /api/catalogue answers for the additions the worker suite makes.
Map<String, dynamic> response() => {
      'schema': 1,
      'characters': [
        {
          'id': 'achilles',
          'name': 'Achilles',
          'vibe': 'Best of the Greeks',
          'desc': 'Swift, proud, and honest about grief.',
          'image': 'assets/images/avatar_achilles_real.jpg',
          'image_url':
              'https://chat.example.test/assets/assets/images/avatar_achilles_real.jpg',
          'color': '#B03A2E',
          'group': 'greek',
          'profile': {
            'age': '27',
            'tags': ['Glory', 'Rage', 'Grief'],
            'about': 'They sing about the rage.',
            'asks': ['Was the glory worth it?'],
            'verse': 'A short life, and a loud one.',
          },
          'nudges': ['The camp is quiet tonight.'],
        },
        {'id': 'zeus', 'desc': 'Rewritten without a release.'},
      ],
      'hidden_characters': ['surfer'],
      'order': {
        'greek': ['achilles', 'odysseus'],
      },
      'gifts': [
        {
          'item': 'lilies',
          'label': 'Lilies',
          'detail': 'White, and already opening.',
          'image': 'assets/images/gift_lilies.png',
          'image_url':
              'https://chat.example.test/assets/assets/images/gift_lilies.png',
          'price': 80,
          'once': false,
          'giving': 'a spray of lilies',
        },
        {'item': 'roses', 'label': 'Red Roses', 'once': true},
      ],
      'hidden_gifts': ['ambrosia'],
      'nudges': {
        'zeus': ['Olympus is dull without an argument.'],
      },
    };

void main() {
  setUp(RemoteCatalogue.debugReset);
  tearDown(RemoteCatalogue.debugReset);

  group('with no catalogue the app is exactly the build', () {
    test('roster, order, profiles and gifts are the compiled-in ones', () {
      expect(identical(kCharacters, kBundledCharacters), isTrue);
      expect(greekCharacterIds, AppConfig.greekCharacterIds);
      expect(modernCharacterIds, AppConfig.modernCharacterIds);
      expect(visibleCharacterIds, AppConfig.visibleCharacterIds);
      expect(identical(kTributeOptions, kBundledTributeOptions), isTrue);
      expect(profileForCharacter('zeus'), same(kCharacterProfiles['zeus']));
      expect(nudgesForCharacter('zeus'), kBundledNudges['zeus']);
    });

    test('every character on the dashboard has notification lines', () {
      // A character without any would speak in the generic voice, which is
      // the thing this feature exists to stop.
      for (final id in AppConfig.visibleCharacterIds) {
        expect(kBundledNudges[id], isNotNull, reason: id);
        expect(kBundledNudges[id]!.length, greaterThanOrEqualTo(3), reason: id);
      }
    });

    test('a switch is off until the worker says otherwise', () {
      expect(RemoteCatalogue.current.feature('leaderboard_names'), isFalse);
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
        'schema': 1,
        'features': {'leaderboard_names': true, 'bogus': 'yes', 'other': false},
      }));
      expect(RemoteCatalogue.current.feature('leaderboard_names'), isTrue);
      expect(RemoteCatalogue.current.feature('bogus'), isFalse,
          reason: 'only a real true counts');
      expect(RemoteCatalogue.current.feature('other'), isFalse);
      expect(RemoteCatalogue.current.feature('never_heard_of_it'), isFalse);
    });

    test('the version line shows one version and, when known, the server build',
        () {
      expect(versionLine(version: '1.0.6', buildNumber: '99', serverBuild: '100'),
          '1.0.6 build 99 · server build 100');
      expect(versionLine(version: '1.0.6', buildNumber: '99'), '1.0.6 build 99');

      expect(RemoteCatalogue.current.serverBuild, isNull);
      RemoteCatalogue.debugSet(
          RemoteCatalogue.tryParse({'schema': 1, 'server_build': '100'}));
      expect(RemoteCatalogue.current.serverBuild, '100');
      // Anything that is not a plain number is not shown.
      for (final junk in ['1.0.7+100', '<b>', '', 100, null]) {
        RemoteCatalogue.debugSet(
            RemoteCatalogue.tryParse({'schema': 1, 'server_build': junk}));
        expect(RemoteCatalogue.current.serverBuild, isNull, reason: '$junk');
      }
    });

    test('an empty response changes nothing', () {
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
        'schema': 1,
        'characters': [],
        'hidden_characters': [],
        'order': {},
        'gifts': [],
        'hidden_gifts': [],
        'nudges': {},
      }));
      expect(identical(kCharacters, kBundledCharacters), isTrue);
      expect(visibleCharacterIds, AppConfig.visibleCharacterIds);
      expect(identical(kTributeOptions, kBundledTributeOptions), isTrue);
    });
  });

  group('responses this build must not act on', () {
    test('a newer schema, or something that is not a catalogue, is ignored',
        () {
      expect(RemoteCatalogue.tryParse({...response(), 'schema': 2}), isNull);
      expect(RemoteCatalogue.tryParse({...response()}..remove('schema')),
          isNull);
      expect(RemoteCatalogue.tryParse('<html>502</html>'), isNull);
      expect(RemoteCatalogue.tryParse(null), isNull);
      expect(RemoteCatalogue.tryParse([1, 2]), isNull);
    });

    test('a broken entry is dropped on its own, not with its neighbours', () {
      final parsed = RemoteCatalogue.tryParse({
        'schema': 1,
        'characters': [
          'not a map',
          {'id': 'Bad Id'},
          {'name': 'no id'},
          {'id': 'half', 'name': 'Half'}, // new, but missing what a card reads
          {'id': 'zeus', 'color': 'red', 'desc': 7},
          response()['characters'][0],
        ],
        'gifts': [
          {'item': 'li:lies', 'label': 'x'},
          {'item': 'orchid', 'label': 'Orchid'}, // no detail, no image
          42,
        ],
        'order': {'greek': 'odysseus', 'modern': [1, 'poet']},
        'hidden_characters': 'surfer',
        'nudges': {'zeus': 'one line, not a list'},
      })!;
      RemoteCatalogue.debugSet(parsed);

      expect(characterById('achilles'), isNotNull);
      expect(characterById('half'), isNull,
          reason: 'a tile with no portrait or colour would be a blank card');
      expect(characterById('Bad Id'), isNull);
      // The bad colour and the non-text desc are dropped; Zeus is untouched.
      expect(characterById('zeus')!['color'],
          kBundledCharacters.firstWhere((c) => c['id'] == 'zeus')['color']);
      expect(characterById('zeus')!['desc'],
          kBundledCharacters.firstWhere((c) => c['id'] == 'zeus')['desc']);
      expect(kTributeOptions.map((o) => o.item),
          kBundledTributeOptions.map((o) => o.item),
          reason: 'neither malformed gift is offered');
      expect(modernCharacterIds, ['poet', 'badboy', 'surfer']);
      expect(nudgesForCharacter('zeus'), kBundledNudges['zeus']);
    });
  });

  group('a catalogue laid over the build', () {
    setUp(() => RemoteCatalogue.debugSet(RemoteCatalogue.tryParse(response())));

    test('a new character is in the roster, with a profile and a portrait URL',
        () {
      final achilles = characterById('achilles')!;
      expect(achilles['name'], 'Achilles');
      expect(achilles['vibe'], 'Best of the Greeks');
      expect(achilles['color'], const Color(0xFFB03A2E));
      // Not compiled into this build, so it is fetched.
      expect(achilles['image'], startsWith('https://'));
      expect(catalogueImageProvider(achilles['image'] as String),
          isA<NetworkImage>());
      expect(profileForCharacter('achilles')!.asks, ['Was the glory worth it?']);
      expect(nudgesForCharacter('achilles'), ['The camp is quiet tonight.']);
    });

    test('a portrait that IS compiled in is drawn from the bundle', () {
      RemoteCatalogue.bundledAssets = {'assets/images/avatar_achilles_real.jpg'};
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse(response()));
      final image = characterById('achilles')!['image'] as String;
      expect(image, 'assets/images/avatar_achilles_real.jpg');
      expect(catalogueImageProvider(image), isA<AssetImage>());
    });

    test('an override replaces only the fields it carries', () {
      final bundled = kBundledCharacters.firstWhere((c) => c['id'] == 'zeus');
      final zeus = characterById('zeus')!;
      expect(zeus['desc'], 'Rewritten without a release.');
      expect(zeus['name'], bundled['name']);
      expect(zeus['image'], bundled['image']);
      expect(zeus['color'], bundled['color']);
      expect(bundled['desc'], isNot('Rewritten without a release.'),
          reason: 'the compiled-in entry is not mutated');
      expect(nudgesForCharacter('zeus'),
          ['Olympus is dull without an argument.']);
    });

    test('the dashboard order follows the worker, then the build', () {
      // order.greek leads; the rest of the build's Greek list follows in its
      // own order, nobody twice.
      expect(greekCharacterIds.take(2), ['achilles', 'odysseus']);
      expect(greekCharacterIds.toSet().length, greekCharacterIds.length);
      expect(greekCharacterIds.toSet(),
          {...AppConfig.greekCharacterIds, 'achilles'});
      expect(modernCharacterIds, isNot(contains('surfer')));
      expect(modernCharacterIds, ['badboy', 'poet']);
    });

    test('a hidden character leaves the dashboard but still resolves', () {
      expect(visibleCharacterIds, isNot(contains('surfer')));
      // Someone mid-conversation with Kai must still get his name and face.
      expect(characterById('surfer'), isNotNull);
    });

    test('a new character with no order joins the end of its group', () {
      final json = response()..remove('order');
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse(json));
      expect(greekCharacterIds, [...AppConfig.greekCharacterIds, 'achilles']);
    });

    test('a character moved to the other tab leaves the first', () {
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
        'schema': 1,
        'characters': [
          {'id': 'cupid', 'group': 'modern'},
        ],
      }));
      expect(greekCharacterIds, isNot(contains('cupid')));
      expect(modernCharacterIds.last, 'cupid');
    });

    test('a new gift is offered, at its place by price', () {
      final lilies = kTributeOptions.firstWhere((o) => o.item == 'lilies');
      expect(lilies.label, 'Lilies');
      expect(lilies.once, isFalse);
      expect(lilies.givingPhrase, 'a spray of lilies');
      expect(lilies.asset, startsWith('https://'));

      final prices = {
        'roses': 50, 'lilies': 80, 'ambrosia': 150, 'pendant': 500,
        'laurel': 1500,
      };
      expect(offeredTributeOptions(prices).map((o) => o.item),
          ['roses', 'lilies', 'pendant', 'laurel'],
          reason: 'cheapest first, and ambrosia is hidden');
    });

    test('a new gift the wallet does not price is not offered', () {
      // The catalogue on this phone and the worker answering can disagree
      // for a few minutes either side of a deploy; a row that can only fail
      // is worse than no row.
      final prices = {'roses': 50, 'ambrosia': 150, 'pendant': 500, 'laurel': 1500};
      expect(offeredTributeOptions(prices).map((o) => o.item),
          isNot(contains('lilies')));
      // Before any wallet read, the build's own gifts are still listed.
      expect(offeredTributeOptions(const {}).map((o) => o.item),
          ['roses', 'pendant', 'laurel']);
    });

    test('a hidden gift is not offered but can still be drawn', () {
      expect(kTributeOptions.map((o) => o.item), contains('ambrosia'),
          reason: 'old chat bubbles and the history still need its art');
      expect(tributeHistoryLabel('ambrosia', 'Penelope'),
          'Ambrosia for Penelope');
    });

    test('a rewrite relabels a gift but can never change whether it is kept',
        () {
      final roses = kTributeOptions.firstWhere((o) => o.item == 'roses');
      expect(roses.label, 'Red Roses');
      expect(roses.once, isFalse,
          reason: 'the ledger keys of every rose already given depend on it');
      expect(roses.asset, 'assets/images/gift_roses.png');
    });
  });
}
