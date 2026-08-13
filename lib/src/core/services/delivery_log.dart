import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'analytics.dart';
import 'delivery_env.dart';

/// Where a line the visitor read actually came from.
///
/// The distinction is the point. All of these render as the character speaking
/// and are indistinguishable on screen, but they fail for unrelated reasons: a
/// missing [aiReply] is a delivery problem, a missing [welcomeScript] bubble is
/// someone leaving before the opening finished, and a [localFallback] means the
/// visitor was told the character was "having trouble thinking" — which reads to
/// them as the product being broken and has no server-side record at all.
///
/// The wire names must match DELIVERY_ORIGINS in backend/src/worker.js, which
/// drops an origin it does not recognise rather than folding it into a known
/// one. Adding a value here means adding it there in the same change.
enum DeliveryOrigin {
  aiReply('ai_reply'),
  welcomeScript('welcome_script'),
  idleNudge('idle_nudge'),
  portrait('portrait'),
  localFallback('local_fallback'),
  systemBanner('system_banner'),
  user('user');

  const DeliveryOrigin(this.wireName);
  final String wireName;
}

/// One bubble's delivery record, as it sits in the local queue.
class _Receipt {
  _Receipt({
    required this.bubbleId,
    required this.turnId,
    required this.seq,
    required this.origin,
    required this.isUser,
    required this.queuedAtMs,
    this.visitId,
    this.chatId,
    this.characterId,
    this.conversationLogId,
    this.text,
    this.textSha256,
    this.textLen,
    this.failureReason,
    this.intendedAt,
    this.renderedAt,
    this.seenAt,
    this.attempts = 0,
    this.dirty = true,
    this.closed = false,
  });

  final String bubbleId;
  final String turnId;
  final int seq;
  final String origin;
  final bool isUser;

  /// When this receipt first entered the queue, by the device clock. Only ever
  /// used as a difference against "now" to produce queued_ms, so a device with
  /// a wrong clock still reports a correct duration.
  final int queuedAtMs;

  final String? visitId;
  final String? chatId;
  final String? characterId;
  final String? conversationLogId;
  final String? text;
  final String? textSha256;
  final int? textLen;
  final String? failureReason;

  String? intendedAt;
  String? renderedAt;
  String? seenAt;
  int attempts;

  /// Whether this receipt is carrying anything the worker has not stored yet.
  ///
  /// False for a receipt that has been acknowledged and has learned nothing
  /// since. Those are kept anyway — see [isComplete] — but must not be resent on
  /// every flush, or each new bubble would drag the whole conversation's history
  /// along with it.
  bool dirty;

  /// Whether the screen that could still stamp this receipt has gone away.
  ///
  /// A receipt is only reachable while its chat screen is alive: the bubble ids
  /// live in that screen's own map, and a message restored from history
  /// deliberately carries none. So once the screen is disposed — or the app
  /// restarted — [DeliveryLog.markRendered] and [DeliveryLog.markSeen] can
  /// never name this receipt again.
  ///
  /// Not persisted, because anything read back from disk is by definition from
  /// a previous run; [fromJson] sets it unconditionally.
  bool closed;

  /// True once there is nothing further to learn about this bubble: it was seen,
  /// so no later event can change the record.
  ///
  /// This is what decides when a receipt may be forgotten, and the distinction
  /// is load-bearing. A bubble's three moments arrive seconds apart — intent is
  /// declared before pacing starts, and the bubble may not be drawn for another
  /// ten seconds — so a receipt dropped as soon as the worker acknowledged its
  /// intent would have nothing left to attach the render and the sighting to,
  /// and both would be lost in silence. Only a sighting ends the story.
  bool get isComplete => seenAt != null;

  /// True once keeping this receipt can no longer teach anything: either the
  /// bubble was seen, or the screen that could have reported it is gone.
  ///
  /// The second half is what stops the queue growing forever. Waiting only on
  /// [isComplete] means a bubble the visitor never scrolled to is kept for a
  /// sighting that has become impossible — and most of a welcome script is
  /// exactly that, so an abandoned opening left dozens of receipts on disk that
  /// nothing could ever complete or remove.
  bool get canDiscard => isComplete || closed;

  Map<String, dynamic> toJson() => {
    'bubbleId': bubbleId,
    'turnId': turnId,
    'seq': seq,
    'origin': origin,
    'isUser': isUser,
    'queuedAtMs': queuedAtMs,
    if (visitId != null) 'visitId': visitId,
    if (chatId != null) 'chatId': chatId,
    if (characterId != null) 'characterId': characterId,
    if (conversationLogId != null) 'conversationLogId': conversationLogId,
    if (text != null) 'text': text,
    if (textSha256 != null) 'textSha256': textSha256,
    if (textLen != null) 'textLen': textLen,
    if (failureReason != null) 'failureReason': failureReason,
    if (intendedAt != null) 'intendedAt': intendedAt,
    if (renderedAt != null) 'renderedAt': renderedAt,
    if (seenAt != null) 'seenAt': seenAt,
    'attempts': attempts,
    'dirty': dirty,
  };

  static _Receipt? fromJson(Map<String, dynamic> json) {
    final bubbleId = json['bubbleId'];
    final turnId = json['turnId'];
    if (bubbleId is! String || turnId is! String) return null;
    return _Receipt(
      bubbleId: bubbleId,
      turnId: turnId,
      seq: json['seq'] is int ? json['seq'] as int : 0,
      origin: json['origin'] is String ? json['origin'] as String : 'ai_reply',
      isUser: json['isUser'] == true,
      queuedAtMs: json['queuedAtMs'] is int
          ? json['queuedAtMs'] as int
          : DateTime.now().millisecondsSinceEpoch,
      visitId: json['visitId'] as String?,
      chatId: json['chatId'] as String?,
      characterId: json['characterId'] as String?,
      conversationLogId: json['conversationLogId'] as String?,
      text: json['text'] as String?,
      textSha256: json['textSha256'] as String?,
      textLen: json['textLen'] as int?,
      failureReason: json['failureReason'] as String?,
      intendedAt: json['intendedAt'] as String?,
      renderedAt: json['renderedAt'] as String?,
      seenAt: json['seenAt'] as String?,
      attempts: json['attempts'] is int ? json['attempts'] as int : 0,
      dirty: json['dirty'] != false,
      // A receipt read back from disk belongs to a run that has ended. Its
      // bubble cannot be stamped again, so it is kept only long enough to be
      // delivered.
      closed: true,
    );
  }
}

/// Records what the app actually put in front of the visitor, and gets it to the
/// worker.
///
/// The server already logs every reply it sends (conversation_logs). What it
/// cannot know is whether the reply reached the screen: one reply is split into
/// several bubbles and paced out over seconds, the text is rewritten before it
/// is drawn, and much of what the character "says" early on is composed on the
/// device and never passes through the worker at all. So the client keeps its own
/// record, and the comparison between the two is the verification.
///
/// Three moments per bubble, because the missing pairs mean different things:
/// intent with no render is a delivery failure, and a render with no sighting is
/// a bubble drawn into a hidden tab or below the fold — delivered but unread.
///
/// Durability is the whole design. A receipt is written to disk before it is
/// sent and deleted only when the worker names it in `acked`, because the
/// sessions worth studying are the ones where the network was failing, and a
/// fire-and-forget post would lose exactly those. The queue therefore survives a
/// reload, and rows can arrive long after the moment they describe — anything
/// reading this data has to treat "not here yet" as different from "never
/// happened".
///
/// Nothing here may ever break a chat. Every entry point swallows its errors;
/// a lost receipt is a gap in a report, while a thrown exception in
/// _addMessage is a visitor staring at a blank screen.
class DeliveryLog {
  DeliveryLog._();

  static final DeliveryLog instance = DeliveryLog._();

  static const String _queueKey = 'delivery_receipt_queue_v1';
  static const String _droppedKey = 'delivery_receipts_dropped_v1';

  /// Waits between failed flushes. Climbs to five minutes and stays there: a
  /// visitor sitting in a dead region for an hour should cost a handful of
  /// requests, not one every two seconds, and the receipts are equally valid
  /// whenever they land.
  static const List<int> _retryBackoffMs = [2000, 5000, 15000, 60000, 300000];

  final Dio _dio = Dio();

  /// Insertion-ordered, keyed by bubble id so a second event for the same bubble
  /// updates the receipt in place instead of queueing a duplicate.
  final Map<String, _Receipt> _pending = {};

  SharedPreferences? _prefs;
  bool _ready = false;

  String? _userId;
  String? _appVersion;
  int? _viewportW;
  int? _viewportH;

  /// Receipts discarded because the queue was full, reported on the next flush
  /// so a truncated record cannot be mistaken for a quiet session.
  int _dropped = 0;

  Timer? _flushTimer;
  Timer? _retryTimer;
  bool _flushing = false;
  int _turnCounter = 0;

  /// Tells apart two devices that began a turn in the same millisecond.
  ///
  /// message_delivery.bubble_id is a primary key across every visitor, and a
  /// turn id of millisecond-plus-counter is not unique enough to be one:
  /// [_turnCounter] restarts at zero each run, which makes `turn_<ms>_1` the
  /// first turn of every session on every device. Two visitors opening a chat
  /// in the same millisecond would then claim the same bubble ids, and the
  /// worker's ON CONFLICT — which does not overwrite user_id or text — would
  /// fold one visitor's bubbles into the other's row instead of rejecting
  /// them. Silently, and leaving the same trace as a delivery failure.
  final String _runTag = _makeRunTag();

  /// Random.secure rather than Random, because the default generator is seeded
  /// from the clock on some platforms — which would correlate on exactly the
  /// two devices this is meant to separate. Falls back instead of throwing:
  /// nothing in this class may break a chat.
  static String _makeRunTag() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    Random random;
    try {
      random = Random.secure();
    } catch (_) {
      random = Random();
    }
    return String.fromCharCodes(
      List.generate(
        6,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }

  /// Set while no chat screen is alive to receive bubbles.
  ///
  /// A retry timer that outlives the screen achieves nothing: the receipts it
  /// would send are already on disk, and the next [init] picks them up. Left
  /// running it is simply a timer nobody is waiting on — which is also why the
  /// existing chat-screen tests failed the moment this class was wired in, with
  /// a five-minute backoff still pending after the tree was disposed.
  bool _stopped = false;

  /// Loads any receipts left over from a previous run and tries to send them.
  ///
  /// The leftovers are the interesting ones — a queue that survived a reload is
  /// usually a queue that could not be delivered — so this runs at startup
  /// rather than waiting for the first new bubble.
  Future<void> init() async {
    // Re-entered every time a chat screen opens, not only on the first one.
    _stopped = false;
    if (_ready) {
      _scheduleFlush();
      return;
    }
    try {
      _prefs = await SharedPreferences.getInstance();
      _ready = true;

      _userId = _ensureUserId(_prefs!);
      _dropped = _prefs!.getInt(_droppedKey) ?? 0;

      final raw = _prefs!.getString(_queueKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map<String, dynamic>) {
              final receipt = _Receipt.fromJson(entry);
              // Still unsent is the only reason to keep one: everything read
              // back from disk is closed, so a receipt the worker has already
              // acknowledged has nothing left to send and no way left to learn
              // anything. Dropping those here is what stops the queue carrying
              // every unseen bubble of every previous session for the life of
              // the install — an abandoned welcome script is dozens of them.
              if (receipt != null && receipt.dirty) {
                _pending[receipt.bubbleId] = receipt;
              }
            }
          }
        }
      }
      // The load above may have discarded some of what is on disk. Write the
      // survivors back rather than waiting for the next bubble, so a run that
      // adds nothing still shrinks the stored queue.
      _persist();

      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // Version is context, not evidence. Carry on without it.
      }

      if (_pending.isNotEmpty) _scheduleFlush();
    } catch (e) {
      if (kDebugMode) debugPrint('DeliveryLog.init failed: $e');
    }
  }

  /// The anonymous id the worker recognises, created here if it does not exist.
  ///
  /// OpenAIService creates the same id under the same key on its first send, but
  /// the welcome script is drawn before any send happens — so without this the
  /// opening bubbles would carry no user id and the worker would drop them as
  /// unrecognised, losing the exact stretch of the session this is meant to
  /// measure. Whichever runs first wins and the other reuses it; the format has
  /// to stay in step with isRealUserId in the worker ("user_" plus a 13-digit
  /// millisecond stamp, 18 characters).
  static String _ensureUserId(SharedPreferences prefs) {
    final existing = prefs.getString('user_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final created = 'user_${DateTime.now().millisecondsSinceEpoch}';
    prefs.setString('user_id', created);
    return created;
  }

  /// The size of the surface the bubbles are being drawn onto, for slicing
  /// failures by something actionable. Set from the chat screen's MediaQuery
  /// rather than read from the window, so it is the same number on both
  /// platforms.
  void setViewport(int width, int height) {
    _viewportW = width;
    _viewportH = height;
  }

  /// A new group of bubbles that belong together: one reply, or one run of the
  /// welcome script.
  String beginTurn() {
    _turnCounter++;
    return 'turn_${_runTag}_${DateTime.now().millisecondsSinceEpoch}_$_turnCounter';
  }

  /// Records that the app has committed to showing this bubble, and returns the
  /// id to report [markRendered] and [markSeen] against.
  ///
  /// Called before any pacing delay, which is what makes a bubble that is never
  /// drawn visible in the data at all. The id is derived from the turn and
  /// sequence rather than random so that recording the same bubble twice
  /// collapses onto one row instead of inventing a second.
  String recordIntended({
    required String turnId,
    required int seq,
    required DeliveryOrigin origin,
    required String text,
    bool isUser = false,
    String? chatId,
    String? characterId,
    String? conversationLogId,
    String? failureReason,
  }) {
    final bubbleId = '${turnId}_$seq';
    try {
      final now = DateTime.now();
      _pending[bubbleId] = _Receipt(
        bubbleId: bubbleId,
        turnId: turnId,
        seq: seq,
        origin: origin.wireName,
        isUser: isUser,
        queuedAtMs: now.millisecondsSinceEpoch,
        visitId: currentVisitId(),
        chatId: chatId,
        characterId: characterId,
        conversationLogId: conversationLogId,
        text: text,
        textSha256: sha256.convert(utf8.encode(text)).toString(),
        textLen: text.length,
        failureReason: failureReason,
        intendedAt: now.toIso8601String(),
      );
      _afterChange();
    } catch (e) {
      if (kDebugMode) debugPrint('DeliveryLog.recordIntended failed: $e');
    }
    return bubbleId;
  }

  /// The bubble reached the widget tree.
  void markRendered(String bubbleId) =>
      _stamp(bubbleId, (r, now) => r.renderedAt ??= now);

  /// The bubble was genuinely on screen — see SeenDetector for what that
  /// requires.
  void markSeen(String bubbleId) =>
      _stamp(bubbleId, (r, now) => r.seenAt ??= now);

  void _stamp(String bubbleId, void Function(_Receipt, String) apply) {
    try {
      final receipt = _pending[bubbleId];
      // Absent means the bubble was seen and its record closed, or the queue
      // evicted it under pressure. Either way there is nothing here to complete.
      //
      // A receipt that has merely been acknowledged is still in this map — it is
      // kept precisely so this lookup succeeds. Dropping acked receipts is what
      // silently lost every render and sighting in the first preview run: intent
      // for a whole reply is declared and flushed within 250ms, while the
      // bubbles it describes are not drawn for another ten seconds.
      if (receipt == null) return;
      apply(receipt, DateTime.now().toIso8601String());
      receipt.dirty = true;
      _afterChange();
    } catch (e) {
      if (kDebugMode) debugPrint('DeliveryLog._stamp failed: $e');
    }
  }

  void _afterChange() {
    _enforceQueueCap();
    _persist();
    _scheduleFlush();
  }

  /// Keeps the queue inside AppConfig.deliveryQueueMax, discarding completed
  /// receipts before incomplete ones.
  ///
  /// A receipt that was seen has already told its whole story; one still waiting
  /// on a render is the potential finding. So when room has to be made, the
  /// finished rows go first and only then the oldest of the rest — and either way
  /// the count travels with the next flush, because a queue that silently
  /// truncated would read as a session that simply went quiet.
  void _enforceQueueCap() {
    final overflow = _pending.length - AppConfig.deliveryQueueMax;
    if (overflow <= 0) return;

    final doomed = <String>[];
    for (final entry in _pending.entries) {
      if (doomed.length >= overflow) break;
      if (entry.value.canDiscard) doomed.add(entry.key);
    }
    // Set rather than a list scan: this runs on every recorded bubble, and
    // contains() over a thousand keys inside a thousand-iteration loop is a
    // million comparisons on the frame that draws the bubble.
    final alreadyDoomed = doomed.toSet();
    for (final key in _pending.keys) {
      if (doomed.length >= overflow) break;
      if (!alreadyDoomed.contains(key)) doomed.add(key);
    }

    for (final key in doomed) {
      _pending.remove(key);
    }
    _dropped += doomed.length;
    _prefs?.setInt(_droppedKey, _dropped);
    if (kDebugMode) {
      debugPrint('DeliveryLog dropped ${doomed.length} receipts (queue full)');
    }
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final encoded = jsonEncode(
        _pending.values.map((r) => r.toJson()).toList(growable: false),
      );
      prefs.setString(_queueKey, encoded);
    } catch (e) {
      if (kDebugMode) debugPrint('DeliveryLog._persist failed: $e');
    }
  }

  /// Stands the queue down when the last chat screen goes away.
  ///
  /// Stops the timers, which have no screen left to serve, and closes the
  /// receipts: with that screen gone nothing holds their bubble ids any more,
  /// so no render or sighting can ever be reported against them again.
  ///
  /// Undelivered receipts stay — on disk, and resumed by the next [init]. What
  /// goes is the ones that were only being kept in the hope of a stamp that has
  /// now become impossible. Leaving those was a slow leak of exactly the
  /// receipts a session produces most of: an opening the visitor walked away
  /// from is dozens of bubbles that were drawn and never seen.
  void stop() {
    _stopped = true;
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    for (final receipt in _pending.values) {
      receipt.closed = true;
    }
    _pending.removeWhere((_, receipt) => !receipt.dirty);
    _persist();
  }

  /// Coalesces the several bubbles of one reply into a single request.
  void _scheduleFlush() {
    if (_stopped) return;
    if (!_hasDirty) return;
    if (_flushTimer?.isActive == true) return;
    _flushTimer = Timer(
      const Duration(milliseconds: AppConfig.deliveryFlushDebounceMs),
      () => flush(),
    );
  }

  /// Sends what is queued, and keeps whatever the worker did not acknowledge.
  ///
  /// Cancels any pending debounce, so calling it directly is the urgent path —
  /// which is what the chat screen does when the surface is going away, as the
  /// last chance to report a bubble that was on screen a second ago.
  Future<void> flush() async {
    if (!_ready) return;
    if (_flushing) return;
    if (_pending.isEmpty) return;

    final url = AppConfig.deliveryUrl();
    if (url.isEmpty) return;

    _flushing = true;
    _flushTimer?.cancel();
    _retryTimer?.cancel();

    try {
      final batch = _pending.values
          .where((r) => r.dirty)
          .take(AppConfig.deliveryBatchMax)
          .toList(growable: false);
      if (batch.isEmpty) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final droppedAtSend = _dropped;

      // Describes the flush rather than any one bubble, so it is built once and
      // copied onto each row. Keeping the distinction visible matters: treating
      // a property of the queue as a property of a bubble is what made the
      // dropped count below wrong in the first place.
      final environment = <String, dynamic>{
        'userId': _userId,
        // Straight off the platform rather than from intl, which reports
        // whatever the app last formatted with and is null until something has.
        // This is the visitor's actual locale, and the same call works on both
        // platforms.
        'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
        'tzOffsetMin': DateTime.now().timeZoneOffset.inMinutes,
      };
      final appVersion = _appVersion;
      if (appVersion != null) environment['appVersion'] = appVersion;
      final connection = connectionType();
      if (connection != null) environment['connectionType'] = connection;
      final viewportW = _viewportW;
      if (viewportW != null) environment['viewportW'] = viewportW;
      final viewportH = _viewportH;
      if (viewportH != null) environment['viewportH'] = viewportH;

      final receipts = <Map<String, dynamic>>[];
      for (var i = 0; i < batch.length; i++) {
        final r = batch[i];
        // queuedAtMs, attempts and dirty are the queue's own bookkeeping —
        // queuedMs and flushAttempts below are what the worker is told.
        final json = r.toJson()
          ..remove('queuedAtMs')
          ..remove('attempts')
          ..remove('dirty');
        receipts.add({
          ...json,
          'queuedMs': max(0, nowMs - r.queuedAtMs),
          'flushAttempts': r.attempts + 1,
          // Carried by one receipt in the batch, not all of them. The count is
          // a property of the queue rather than of any bubble, and the admin
          // report sums the column across rows — so repeating it on every
          // receipt would multiply the loss by the batch size, and forty
          // receipts each saying "five were dropped" would read as two hundred.
          if (droppedAtSend > 0 && i == 0) 'queueDropped': droppedAtSend,
          ...environment,
        });
      }

      final body = jsonEncode({'receipts': receipts});

      // Signed with the timestamp of this flush, not of the bubbles inside it.
      // The worker refuses anything older than five minutes as a replay, and a
      // receipt that waited out an outage is far older than that by the time it
      // leaves — the bubble's own clock is in the body, where nothing expires it.
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await _dio.post(
        url,
        data: body,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'x-signature': _sign(body, timestamp),
            'x-timestamp': timestamp,
          },
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final acked = data is Map && data['acked'] is List
            ? (data['acked'] as List).whereType<String>().toSet()
            : const <String>{};

        for (final id in acked) {
          final receipt = _pending[id];
          if (receipt == null) continue;
          if (receipt.canDiscard) {
            // Seen, or belonging to a screen that has gone: either way the
            // record is finished and nothing further can arrive for it.
            _pending.remove(id);
          } else {
            // Stored, but the bubble may still be drawn or come into view. Keep
            // it so those stamps have somewhere to land, and stop resending it
            // until one of them does.
            receipt.dirty = false;
          }
        }

        // Only now is the dropped count safely delivered. Clearing it before
        // the acknowledgement would lose the one signal that says this
        // session's record is incomplete.
        if (acked.isNotEmpty && droppedAtSend > 0) {
          _dropped -= droppedAtSend;
          if (_dropped < 0) _dropped = 0;
          _prefs?.setInt(_droppedKey, _dropped);
        }

        // A receipt the worker did not name is one it never stored, so leave it
        // queued and count the attempt against it.
        for (final receipt in batch) {
          if (!acked.contains(receipt.bubbleId)) receipt.attempts++;
        }
        _persist();

        // More waiting behind this batch — keep going rather than waiting for
        // the next bubble to trigger a flush.
        //
        // Asks whether anything is still *unsent*, not whether the queue is
        // non-empty: acknowledged receipts stay in it until their bubble is
        // seen, so an emptiness check here would reschedule itself every 50ms
        // forever.
        if (_hasDirty) _scheduleRetry(immediate: true);
        return;
      }

      // Anything else (503 when the migration is unapplied, 401, a proxy's 502)
      // means nothing was stored. Keep the batch.
      for (final receipt in batch) {
        receipt.attempts++;
      }
      _persist();
      _scheduleRetry();
    } catch (e) {
      // The case this table exists for: the request never arrived. Keep every
      // receipt and try again later.
      for (final receipt in _pending.values
          .where((r) => r.dirty)
          .take(AppConfig.deliveryBatchMax)) {
        receipt.attempts++;
      }
      _persist();
      _scheduleRetry();
      if (kDebugMode) debugPrint('DeliveryLog.flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Whether anything is waiting to be sent, as opposed to merely being
  /// remembered so a later stamp has somewhere to land.
  bool get _hasDirty => _pending.values.any((r) => r.dirty);

  void _scheduleRetry({bool immediate = false}) {
    _retryTimer?.cancel();
    if (_stopped) return;
    if (!_hasDirty) return;

    if (immediate) {
      _retryTimer = Timer(const Duration(milliseconds: 50), () => flush());
      return;
    }

    final attempts = _pending.values.where((r) => r.dirty).fold<int>(
      0,
      (worst, r) => r.attempts > worst ? r.attempts : worst,
    );
    final index = min(max(attempts - 1, 0), _retryBackoffMs.length - 1);
    _retryTimer = Timer(
      Duration(milliseconds: _retryBackoffMs[index]),
      () => flush(),
    );
  }

  String _sign(String body, String timestamp) {
    final secret = AppConfig.appSecret;
    // Empty on web by design (see AppConfig.appSecret), where the worker runs
    // with REQUIRE_SIGNATURE=false. Same shape as OpenAIService, which also
    // sends an empty signature there rather than omitting the header.
    if (secret.isEmpty) return '';
    return Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode(body + timestamp))
        .toString();
  }

  /// Test seam: how many receipts are waiting, and how many were discarded.
  @visibleForTesting
  int get pendingCount => _pending.length;

  @visibleForTesting
  int get droppedCount => _dropped;

  /// How many of those are still waiting to be sent, as opposed to being held
  /// open for a stamp. The difference is what [_Receipt.dirty] exists for, and
  /// getting it wrong is invisible from [pendingCount] alone.
  @visibleForTesting
  int get unsentCount => _pending.values.where((r) => r.dirty).length;

  /// A DeliveryLog that is not the singleton, so one test's queue cannot leak
  /// into the next. Production has exactly one, reached through [instance].
  @visibleForTesting
  static DeliveryLog debugCreate() => DeliveryLog._();

  /// The Dio the flush posts through, so a test can give it an adapter instead
  /// of a network.
  @visibleForTesting
  Dio get debugDio => _dio;
}
