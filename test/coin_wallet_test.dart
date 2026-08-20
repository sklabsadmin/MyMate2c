// The client half of Mythos Coins: what the wallet parser is allowed to
// believe. Every test is named for the mistake it catches — the classic ones
// here are treating "switched off" as "broke", treating "no wallet" as
// "empty wallet", and letting the client invent a price.

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_boyfriend_chat/src/core/config/app_config.dart';
import 'package:ai_boyfriend_chat/src/features/wallet/coin_wallet.dart';

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

  test('the ♥ mapping covers exactly the tribute sizes the server prices', () {
    // If a size is ever added server-side, the meter mapping must be extended
    // in the same change — a missing entry silently scores zero.
    expect(AppConfig.tributeHeartScore.keys.toSet(), {'small', 'medium', 'large'});
    expect(AppConfig.tributeHeartScore['small'], 1);
    expect(AppConfig.tributeHeartScore['medium'], 3);
    expect(AppConfig.tributeHeartScore['large'], 10);
  });
}
