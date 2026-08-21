// The client half of Mythos Coins: what the wallet parser is allowed to
// believe. Every test is named for the mistake it catches — the classic ones
// here are treating "switched off" as "broke", treating "no wallet" as
// "empty wallet", and letting the client invent a price.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_boyfriend_chat/src/core/config/app_config.dart';
import 'package:ai_boyfriend_chat/src/features/wallet/coin_wallet.dart';
import 'package:ai_boyfriend_chat/src/features/wallet/presentation/coins_sheet.dart';

void main() {
  test('enabled:false parses as a disabled wallet, never as a zero balance', () {
    final state = CoinWalletState.fromResponse({'enabled': false});
    expect(state, isNotNull);
    expect(state!.enabled, isFalse);
    // A disabled wallet must not look like a poor one.
    expect(state.balance, 0);
    expect(state.tributePrices, isEmpty);
  });

  test('wallet:null (an unrecognised id) parses as no wallet at all', () {
    final state = CoinWalletState.fromResponse({'enabled': true, 'wallet': null});
    expect(state, isNull);
  });

  test('a full response carries balance, prices and grants through intact', () {
    final state = CoinWalletState.fromResponse({
      'enabled': true,
      'granted': [
        {'reason': 'welcome', 'delta': 80},
        {'reason': 'daily', 'delta': 20},
      ],
      'wallet': {
        'balance': 100,
        'lifetime_earned': 100,
        'lifetime_spent': 0,
        'today': {'reply_grants': 3, 'reply_grant_cap': 20},
        'prices': {
          'gift': {'small': 5, 'medium': 15, 'large': 50},
        },
        'recent': [
          {'id': 'grant:welcome:u', 'delta': 80, 'kind': 'grant', 'reason': 'welcome'},
        ],
      },
    });
    expect(state, isNotNull);
    expect(state!.enabled, isTrue);
    expect(state.balance, 100);
    expect(state.replyGrantsToday, 3);
    expect(state.tributePrices, {'small': 5, 'medium': 15, 'large': 50});
    expect(state.lastGranted.map((g) => g.reason), ['welcome', 'daily']);
    expect(state.recent, hasLength(1));
  });

  test('grant labels survive a reason the client has never heard of', () {
    // A new server-side faucet must show up as itself in a toast, not crash it.
    const grant = CoinGrant('prophecy', 7);
    expect(grant.label, 'prophecy');
    expect(const CoinGrant('daily', 25).label, 'Dawn offering');
  });

  test('every gift in the catalogue has a ♥ value, and nothing else does', () {
    // Two lists that must agree and live in different files: the catalogue the
    // sheet draws, and the ♥ mapping the chat screen scores with. A gift added
    // to one and not the other silently scores zero — this is the test that
    // fails instead.
    expect(
      AppConfig.tributeHeartScore.keys.toSet(),
      kTributeOptions.map((o) => o.item).toSet(),
    );
    expect(AppConfig.tributeHeartScore['roses'], 1);
    expect(AppConfig.tributeHeartScore['ambrosia'], 3);
    expect(AppConfig.tributeHeartScore['pendant'], 10);
  });

  test('every gift in the catalogue has artwork on disk, at a shippable size', () {
    // A renamed or missing asset is a grey box in production and a green test
    // suite everywhere else — Flutter resolves assets at runtime, so nothing
    // else in this project would notice. The size ceiling is here because
    // assets/images is globbed into every deploy: the source art for these
    // three was 4.8MB, and unprepared it would have gone out with the app.
    for (final option in kTributeOptions) {
      final file = File(option.asset);
      expect(file.existsSync(), isTrue,
          reason: '${option.item} points at ${option.asset}, which is not there');
      expect(file.lengthSync(), lessThan(60 * 1024),
          reason: '${option.asset} is too heavy to glob into every deploy');
      // The name has to be derivable from the item key, or the next gift gets
      // wired to the wrong picture.
      expect(option.asset, 'assets/images/gift_${option.item}.png');
    }
  });

  test('the pendant is the only gift given once, and the sheet knows it', () {
    // once:true is what makes the row read "Worn" instead of a price, and it
    // must match the server's COINS.gifts — where the pendant's ledger id is
    // derived from (user, character) precisely so it cannot be bought twice.
    final once = kTributeOptions.where((o) => o.once).map((o) => o.item);
    expect(once, ['pendant']);
  });

  test('worn pendants come back off the wire as character ids', () {
    final state = CoinWalletState.fromResponse({
      'enabled': true,
      'wallet': {
        'balance': 400,
        'prices': {
          'gift': {'roses': 50, 'ambrosia': 150, 'pendant': 500},
        },
        'pendants': ['odysseus', 'penelope'],
      },
    });
    expect(state!.pendants, ['odysseus', 'penelope']);
    expect(state.tributePrices['pendant'], 500);
  });

  test('a wallet that has never been read prices nothing, rather than zero', () {
    // An empty price map means "not priced yet". The sheet must disable those
    // rows — a row showing 0 would look free.
    final state = CoinWalletState.fromResponse({
      'enabled': true,
      'wallet': {'balance': 100},
    });
    expect(state!.tributePrices, isEmpty);
    expect(state.pendants, isEmpty);
  });
}
