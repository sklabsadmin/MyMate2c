// The durable half of delivery logging: what the queue keeps, what it sends,
// and — the part that was wrong — what it is allowed to forget.
//
// SeenDetector decides whether a bubble was seen. This decides whether that
// answer ever reaches the worker, and it is the harder half to reason about,
// because every failure here is silent and every one of them produces the same
// shape as the regional delivery fault the table exists to detect: intent
// recorded, nothing after. A test that only checks the happy path would have
// passed against all three bugs pinned down below.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_boyfriend_chat/src/core/services/delivery_log.dart';

/// Stands in for the network, and records what went over it.
///
/// The whole point of this class is what happens when a post fails, so the
/// adapter can ack, refuse, or refuse to connect at all, and every test drives
/// the queue through the same seam.
class _FakeAdapter implements HttpClientAdapter {
  /// Decoded request bodies, oldest first.
  final List<Map<String, dynamic>> posts = [];
  final List<Map<String, List<String>>> headers = [];

  /// Set to refuse with a status code, or to throw as a dead connection does.
  int status = 200;
  bool offline = false;

  /// Ids to ack, or null to ack whatever arrived — which is what the real
  /// worker does for any receipt carrying an id.
  List<String>? ackOnly;

  List<dynamic> get lastReceipts => posts.last['receipts'] as List<dynamic>;

  Map<String, dynamic> receiptAt(int index) =>
      lastReceipts[index] as Map<String, dynamic>;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final raw = options.data is String
        ? options.data as String
        : utf8.decode(await _collect(requestStream));
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    posts.add(decoded);
    headers.add(options.headers.map(
      (key, value) => MapEntry(key, [value.toString()]),
    ));

    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'test: no route to host',
      );
    }

    if (status != 200) {
      return ResponseBody.fromString('{"error":"nope"}', status, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }

    final acked = ackOnly ??
        (decoded['receipts'] as List<dynamic>)
            .map((r) => (r as Map<String, dynamic>)['bubbleId'] as String)
            .toList();
    return ResponseBody.fromString(jsonEncode({'acked': acked}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  Future<List<int>> _collect(Stream<Uint8List>? stream) async {
    if (stream == null) return const [];
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter adapter;
  final started = <DeliveryLog>[];

  /// A DeliveryLog wired to the fake network. Not the singleton: these tests
  /// care about what survives a restart, and a shared instance would carry one
  /// test's queue into the next.
  Future<DeliveryLog> boot() async {
    final log = DeliveryLog.debugCreate();
    log.debugDio.httpClientAdapter = adapter;
    await log.init();
    started.add(log);
    return log;
  }

  /// Records one bubble and returns its receipt id.
  String record(DeliveryLog log, String turnId, int seq, String text) {
    return log.recordIntended(
      turnId: turnId,
      seq: seq,
      origin: DeliveryOrigin.aiReply,
      text: text,
      chatId: 'odysseus',
      characterId: 'odysseus',
    );
  }

  setUp(() {
    adapter = _FakeAdapter();
    SharedPreferences.setMockInitialValues({});
    // AppConfig reads both of these off dotenv when not on web. The URL only
    // has to parse — nothing here reaches a socket — but the secret is real,
    // because the signature it produces is part of what is being checked.
    dotenv.loadFromString(
      envString: 'WORKER_URL=http://localhost:9999\nAPP_SECRET=testsecret',
    );
  });

  tearDown(() {
    // Every instance holds a debounce or a backoff timer. Left running they
    // fire into a torn-down binding and fail an unrelated test.
    for (final log in started) {
      log.stop();
    }
    started.clear();
  });

  group('the round trip', () {
    test('a receipt is sent, and forgotten once its bubble is seen', () async {
      final log = await boot();
      final id = record(log, log.beginTurn(), 0, 'Tell me of the wanderer.');
      expect(log.pendingCount, 1);

      log.markRendered(id);
      log.markSeen(id);
      await log.flush();

      expect(adapter.posts, hasLength(1));
      final sent = adapter.receiptAt(0);
      expect(sent['bubbleId'], id);
      expect(sent['origin'], 'ai_reply');
      expect(sent['intendedAt'], isNotNull);
      expect(sent['renderedAt'], isNotNull);
      expect(sent['seenAt'], isNotNull);
      expect(sent['textLen'], 'Tell me of the wanderer.'.length);
      expect(log.pendingCount, 0, reason: 'seen and acked ends the story');
    });

    test('an acked receipt is kept so a later sighting has somewhere to land',
        () async {
      // The first of the four silent bugs: intent for a whole reply is flushed
      // within 250ms, and the bubbles it describes are not drawn for another
      // ten seconds. Deleting a receipt on ack meant every render and every
      // sighting arrived to find its receipt already gone.
      final log = await boot();
      final id = record(log, log.beginTurn(), 0, 'Sing in me, Muse.');

      await log.flush();
      expect(log.pendingCount, 1, reason: 'the bubble has not been seen yet');
      expect(log.unsentCount, 0, reason: 'but there is nothing left to send');

      log.markRendered(id);
      log.markSeen(id);
      expect(log.unsentCount, 1, reason: 'a stamp makes it worth sending again');

      await log.flush();
      expect(adapter.posts, hasLength(2));
      expect(adapter.receiptAt(0)['seenAt'], isNotNull);
      expect(log.pendingCount, 0);
    });

    test('an acked receipt is not resent alongside the next bubble', () async {
      // Without the dirty flag every new bubble drags the whole conversation
      // along with it, and a long session posts a quadratic amount of nothing.
      final log = await boot();
      final turn = log.beginTurn();
      final first = record(log, turn, 0, 'first');
      await log.flush();

      final second = record(log, turn, 1, 'second');
      await log.flush();

      expect(adapter.posts, hasLength(2));
      expect(adapter.lastReceipts, hasLength(1));
      expect(adapter.receiptAt(0)['bubbleId'], second);
      expect(adapter.receiptAt(0)['bubbleId'], isNot(first));
    });
  });

  group('what the queue is allowed to forget', () {
    test('standing down releases receipts nothing can complete', () async {
      // The leak. A receipt is only reachable through the chat screen's own map
      // of bubble ids, so once that screen is gone no sighting can ever be
      // reported against it — and waiting for one anyway kept it forever. Most
      // of a welcome script is exactly this case: drawn, never scrolled to.
      final log = await boot();
      final turn = log.beginTurn();
      final drawn = record(log, turn, 0, 'seen by nobody');
      log.markRendered(drawn);
      await log.flush();

      expect(log.pendingCount, 1, reason: 'still open for a sighting');

      log.stop();

      expect(log.pendingCount, 0,
          reason: 'with the screen gone the sighting can never arrive');
    });

    test('standing down keeps what has not been delivered', () async {
      // The other half: closing a receipt must not throw away one the worker
      // has never seen. Those are the whole point of a durable queue.
      adapter.status = 503;
      final log = await boot();
      record(log, log.beginTurn(), 0, 'never landed');
      await log.flush();

      log.stop();

      expect(log.pendingCount, 1);
      expect(log.unsentCount, 1);
    });

    test('a previous run leaves behind only what it never delivered', () async {
      // Same rule, one restart later. Everything read back from disk belongs to
      // a run that has ended, so a receipt already acknowledged has nothing
      // left to send and no way left to learn anything.
      SharedPreferences.setMockInitialValues({
        'delivery_receipt_queue_v1': jsonEncode([
          {
            'bubbleId': 'turn_abc123_1_0',
            'turnId': 'turn_abc123_1',
            'seq': 0,
            'origin': 'welcome_script',
            'isUser': false,
            'queuedAtMs': 1,
            'intendedAt': '2026-08-13T00:00:00.000',
            'renderedAt': '2026-08-13T00:00:01.000',
            'dirty': false,
          },
          {
            'bubbleId': 'turn_abc123_1_1',
            'turnId': 'turn_abc123_1',
            'seq': 1,
            'origin': 'welcome_script',
            'isUser': false,
            'queuedAtMs': 2,
            'intendedAt': '2026-08-13T00:00:02.000',
            'dirty': true,
          },
        ]),
      });

      final log = await boot();

      expect(log.pendingCount, 1, reason: 'the acked one is not worth keeping');
      expect(log.unsentCount, 1);

      await log.flush();
      expect(adapter.lastReceipts, hasLength(1));
      expect(adapter.receiptAt(0)['bubbleId'], 'turn_abc123_1_1');
      expect(log.pendingCount, 0,
          reason: 'delivered, and from a run that can no longer stamp it');
    });

    test('an undelivered receipt survives a restart and lands next run',
        () async {
      adapter.status = 503;
      final first = await boot();
      record(first, first.beginTurn(), 0, 'waited out an outage');
      await first.flush();
      first.stop();

      // Same backing store, new instance: what the next launch would see.
      adapter.status = 200;
      final second = await boot();

      expect(second.pendingCount, 1);
      await second.flush();

      expect(adapter.posts.last['receipts'], hasLength(1));
      expect(adapter.receiptAt(0)['text'], 'waited out an outage');
      expect(second.pendingCount, 0);
    });
  });

  group('the dropped count', () {
    test('rides on one receipt in the batch, not on every one', () async {
      // The admin report sums queue_dropped across rows. Stamping it on each
      // receipt multiplied the reported loss by the batch size — three receipts
      // carrying "seven dropped" would have read as twenty-one.
      SharedPreferences.setMockInitialValues({
        'delivery_receipts_dropped_v1': 7,
      });
      final log = await boot();
      final turn = log.beginTurn();
      record(log, turn, 0, 'a');
      record(log, turn, 1, 'b');
      record(log, turn, 2, 'c');

      await log.flush();

      expect(adapter.lastReceipts, hasLength(3));
      final carried = adapter.lastReceipts
          .map((r) => (r as Map<String, dynamic>)['queueDropped'])
          .where((v) => v != null)
          .toList();
      expect(carried, [7], reason: 'exactly one row states the loss');
    });

    test('is only cleared once the worker has acknowledged it', () async {
      // Clearing on send would lose the one signal that says this session's
      // record is incomplete.
      SharedPreferences.setMockInitialValues({
        'delivery_receipts_dropped_v1': 7,
      });
      adapter.status = 503;
      final log = await boot();
      record(log, log.beginTurn(), 0, 'a');

      await log.flush();
      expect(log.droppedCount, 7, reason: 'nothing was stored, nothing is told');

      adapter.status = 200;
      await log.flush();
      expect(log.droppedCount, 0);
    });
  });

  group('when delivery fails', () {
    test('a refused flush keeps the batch and counts the attempt', () async {
      adapter.status = 503;
      final log = await boot();
      record(log, log.beginTurn(), 0, 'the migration is not applied yet');

      await log.flush();
      expect(log.pendingCount, 1);
      expect(log.unsentCount, 1);
      expect(adapter.receiptAt(0)['flushAttempts'], 1);

      adapter.status = 200;
      await log.flush();
      expect(adapter.receiptAt(0)['flushAttempts'], 2,
          reason: 'the worker is told how hard this row was to deliver');
      expect(log.pendingCount, 1, reason: 'acked, still open for a sighting');
      expect(log.unsentCount, 0);
    });

    test('a request that never arrives keeps every receipt', () async {
      // The case the whole table exists for: when delivery breaks the server
      // hears nothing, so the client has to be the one that remembers.
      adapter.offline = true;
      final log = await boot();
      final turn = log.beginTurn();
      record(log, turn, 0, 'a');
      record(log, turn, 1, 'b');

      await log.flush();

      expect(log.pendingCount, 2);
      expect(log.unsentCount, 2);
    });

    test('new activity defers to a pending backoff instead of flushing', () async {
      // Observed live: during an outage, every new bubble's render stamp
      // scheduled its own 250ms flush, so the retry backoff never governed —
      // 21 attempts in two minutes against a design intent of "a handful".
      // The failed flush's backoff must own the schedule; a new receipt loses
      // nothing by waiting, because the retry sends everything dirty.
      adapter.status = 503;
      final log = await boot();
      final turn = log.beginTurn();
      record(log, turn, 0, 'first, which fails');
      await log.flush();
      expect(log.debugRetryScheduled, isTrue, reason: 'backoff is pending');

      record(log, turn, 1, 'second, arriving mid-backoff');

      expect(log.debugFlushScheduled, isFalse,
          reason: 'the backoff owns the schedule, not the debounce');
      expect(log.debugRetryScheduled, isTrue);

      // And the deferred receipt rides along when the retry does fire.
      adapter.status = 200;
      await log.flush();
      expect(adapter.lastReceipts, hasLength(2));
    });

    test('a fresh receipt with no failure behind it still debounces', () async {
      // The other half of the rule above: deferral is only for backoff. In the
      // happy path the 250ms debounce must still coalesce a reply's bubbles.
      final log = await boot();
      record(log, log.beginTurn(), 0, 'no outage anywhere');
      expect(log.debugFlushScheduled, isTrue);
      expect(log.debugRetryScheduled, isFalse);
    });

    test('a receipt the worker declined to name stays queued', () async {
      final log = await boot();
      final turn = log.beginTurn();
      final kept = record(log, turn, 0, 'a');
      final acked = record(log, turn, 1, 'b');
      adapter.ackOnly = [acked];

      await log.flush();

      expect(log.unsentCount, 1);
      expect(log.pendingCount, 2);
      adapter.ackOnly = null;
      await log.flush();
      expect(adapter.lastReceipts, hasLength(1));
      expect(adapter.receiptAt(0)['bubbleId'], kept);
    });
  });

  group('identity', () {
    test('two runs cannot claim the same bubble id', () async {
      // message_delivery.bubble_id is a primary key across every visitor, and
      // the turn counter restarts at zero each run — so without a per-run tag
      // `turn_<ms>_1` is the first turn of every session on every device, and
      // two visitors opening a chat in the same millisecond would silently
      // merge into one row rather than be rejected.
      final a = DeliveryLog.debugCreate();
      final b = DeliveryLog.debugCreate();

      final turnA = a.beginTurn();
      final turnB = b.beginTurn();

      String tagOf(String turnId) => turnId.split('_')[1];
      expect(turnA.split('_'), hasLength(4), reason: 'turn_<tag>_<ms>_<n>');
      expect(tagOf(turnA), isNot(tagOf(turnB)));
      expect(turnA, isNot(turnB));
    });

    test('the same bubble recorded twice collapses onto one receipt', () async {
      final log = await boot();
      final turn = log.beginTurn();
      final first = record(log, turn, 0, 'said once');
      final again = record(log, turn, 0, 'said once');

      expect(again, first);
      expect(log.pendingCount, 1);
    });
  });

  group('what queued_ms measures', () {
    test('a stamp on a clean receipt restarts the clock', () async {
      // Observed live: measured from intent, a receipt acknowledged instantly
      // and seen two minutes later reported queued_ms of two minutes — dwell
      // time wearing an outage's clothes. One hidden-tab session put 46 rows
      // in the report's over-a-minute bucket without the network ever failing.
      // The clock must measure undelivered information, so it restarts when a
      // clean receipt turns dirty again.
      final log = await boot();
      final id = record(log, log.beginTurn(), 0, 'acked, then dwelled on');
      final atIntent = log.debugDirtyAtMs(id)!;

      await log.flush();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      log.markSeen(id);

      final atSeen = log.debugDirtyAtMs(id)!;
      expect(atSeen - atIntent, greaterThanOrEqualTo(40),
          reason: 'the dwell before the sighting is not queue delay');
    });

    test('a stamp on a still-dirty receipt keeps the older clock', () async {
      // The reset is only for clean receipts. While one is still undelivered,
      // the oldest waiting information sets the age — a render arriving during
      // an outage must not make the outage look shorter.
      adapter.status = 503;
      final log = await boot();
      final id = record(log, log.beginTurn(), 0, 'never delivered');
      final atIntent = log.debugDirtyAtMs(id)!;

      await log.flush();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      log.markRendered(id);

      expect(log.debugDirtyAtMs(id), atIntent);
    });

    test('a receipt that waited on disk reports the whole wait', () async {
      // Fixture written with the legacy key, which doubles as the fallback
      // test: a queue persisted before the rename measured from intent, and
      // for a row still undelivered that is the same moment.
      SharedPreferences.setMockInitialValues({
        'delivery_receipt_queue_v1': jsonEncode([
          {
            'bubbleId': 'turn_old1_1_0',
            'turnId': 'turn_old1_1',
            'seq': 0,
            'origin': 'welcome_script',
            'isUser': false,
            'queuedAtMs': 1000,
            'intendedAt': '2026-08-13T00:00:00.000',
            'dirty': true,
          },
        ]),
      });
      final log = await boot();
      await log.flush();

      final sent = adapter.receiptAt(0);
      expect(sent['queuedMs'], greaterThan(1000 * 1000 * 1000),
          reason: 'epoch 1000ms to now is decades — the wait survived intact');
    });
  });

  test('a flush is signed with its own timestamp, not the bubble\'s', () async {
    // The receipt in the body may be hours old; the signature must not be, or
    // the worker rejects exactly the evidence that outlasted an outage.
    final log = await boot();
    record(log, log.beginTurn(), 0, 'a');

    await log.flush();

    final sent = adapter.headers.last;
    expect(sent['x-signature']!.single, isNotEmpty);
    final stamp = int.parse(sent['x-timestamp']!.single);
    expect(
      (DateTime.now().millisecondsSinceEpoch - stamp).abs(),
      lessThan(5 * 60 * 1000),
      reason: 'inside the worker freshness window',
    );
  });
}
