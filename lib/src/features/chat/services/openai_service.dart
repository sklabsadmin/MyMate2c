import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/analytics.dart';
import '../data/chat_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OpenAIService {
  final List<Map<String, dynamic>> _conversationHistory = [];
  final String? _scenario;
  final String? _characterId;
  String _currentLanguage = 'English';
  final Dio _dio = Dio();

  /// True only when the most recent [sendMessage] produced a real AI reply
  /// (not a rate-limit/error/"trouble thinking" fallback). Used to decide
  /// whether the free-reply counter should increment.
  bool lastSendSucceeded = false;

  /// The conversation_logs id the worker assigned to the most recent reply, or
  /// null when there was no reply to log (a network failure, or a message this
  /// service answered locally without asking the backend).
  ///
  /// Delivery receipts carry it so a bubble on screen can be lined up against
  /// the reply it was cut from. Nothing else can do that job: one reply becomes
  /// several bubbles, and the text is rewritten below before any of it is drawn,
  /// so matching on content afterwards would be guesswork.
  String? lastLogId;

  /// The `wallet` block the worker attached to the most recent response, or
  /// null when there was none (feature off never sends one to draw; a network
  /// failure sends nothing at all). Read by the chat screen and forwarded to
  /// the coin provider — this service stays a courier, not a wallet.
  Map<String, dynamic>? lastWallet;

  /// Why the most recent [sendMessage] failed, or null if it succeeded.
  ///
  /// "network" is the important one: the request never reached the worker, so
  /// there is no server-side log row for it at all, and without this the
  /// failure is indistinguishable from the user never having typed anything.
  /// The rest ("http_500", "empty_response", ...) do have server rows, and
  /// comparing the two tells you how many sends died in transit.
  String? lastFailureReason;

  OpenAIService({
    List<dynamic> history = const [],
    String language = 'English',
    String? scenario,
    String? characterId,
  }) : _scenario = scenario,
       _characterId = characterId {
    _currentLanguage = language;

    // Validate Config
    final workerUrl = AppConfig.workerUrl;
    if (workerUrl.isEmpty) {
      print("❌ CRITICAL ERROR: WORKER_URL is empty! Check your .env file.");
    }

    _initializeHistory(history, scenario);
  }

  void _initializeHistory(List<dynamic> history, String? scenario) {
    // Add system instruction with language
    String systemInstruction = ChatPrompt.systemInstruction;
    if (scenario != null && scenario.isNotEmpty) {
      systemInstruction +=
          "\n\nCRITICAL ROLEPLAY INSTRUCTION:\n- CONTEXT: '$scenario'\n- YOUR ROLE: You are the boyfriend/male lead in this scenario. Adopt the personality fitting this context.\n- USER'S ROLE: The user is your partner.\n- Do NOT confuse these roles.";
    }

    final systemPrompt = '''$systemInstruction

LANGUAGE: Respond ONLY in $_currentLanguage. All your messages must be in $_currentLanguage.''';

    _conversationHistory.add({"role": "system", "content": systemPrompt});

    // Convert chat history
    // OPTIMIZATION: Only load last 30 messages
    final recentHistory = history.length > 30
        ? history.sublist(history.length - 30)
        : history;

    for (var msg in recentHistory) {
      _conversationHistory.add({
        "role": msg.isUser ? "user" : "assistant",
        "content": msg.text,
      });
    }
  }

  /// Records something the character said that this service did not generate.
  ///
  /// A scripted opening is posted straight into the chat by the UI, so without
  /// this the model's first sight of the conversation is the visitor's reply on
  /// its own — it never learns that it opened by asking "what made you stay?"
  /// or that it already told them about Ogygia. Two things break as a result:
  /// a bare answer ("the second one") has nothing to attach to, and the model
  /// re-asks a question the visitor has just been asked.
  ///
  /// Pass one turn per call, not one bubble: the opening is dozens of bubbles
  /// and, at one history entry each, it would push everything else out of the
  /// 30-message window the moment the conversation got going.
  void recordAssistantTurn(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _conversationHistory.add({"role": "assistant", "content": trimmed});
  }

  Future<String> sendMessage(String message, {Map<String, dynamic>? gift}) async {
    lastSendSucceeded = false;
    lastFailureReason = null;
    lastLogId = null;
    lastWallet = null;
    // 1. FILTER: Block translation requests locally (First line of defense)
    const badPatterns = ["translate", "翻译", "to zh"];
    if (badPatterns.any((p) => message.toLowerCase().contains(p))) {
      return "I'm your boyfriend, not a translator. Let's focus on us. 😘";
    }

    try {
      // Add user message to history
      _conversationHistory.add({"role": "user", "content": message});

      // Maintain history size
      while (_conversationHistory.length > 31) {
        _conversationHistory.removeAt(1); // Keep System at [0]
      }

      // Prepare Request Body
      final requestBody = jsonEncode({
        "messages": _conversationHistory,
        // Model and params are enforced by Backend, but we send structure
        // A tribute rides on an ordinary turn; the worker prices it (the
        // client only ever names the size) and debits before calling anyone.
        if (gift != null) "gift": gift,
      });

      // Generate HMAC Headers
      final prefs = await SharedPreferences.getInstance();
      var userId = prefs.getString('user_id');
      if (userId == null) {
        userId = 'user_${DateTime.now().millisecondsSinceEpoch}';
        await prefs.setString('user_id', userId);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final signature = _generateHmacSignature(requestBody, timestamp);
      final scenario = _scenario;
      final headers = {
        'Content-Type': 'application/json',
        'x-signature': signature,
        'x-timestamp': timestamp,
        'x-user-id': userId,
        'x-chat-id': scenario ?? 'default',
        'x-language': _currentLanguage,
      };
      if (scenario != null) {
        headers['x-scenario'] = scenario;
      }
      if (_characterId != null && _characterId!.isNotEmpty) {
        headers['x-character-id'] = _characterId!;
      }
      // Ties this message to the browser visit that sent it, so the server can
      // answer "how many messages did this session manage before quitting".
      // Null off the web, where there is no page load to belong to.
      final visitId = currentVisitId();
      if (visitId != null && visitId.isNotEmpty) {
        headers['x-visit-id'] = visitId;
      }

      // Call Backend Worker
      final response = await _dio.post(
        AppConfig.chatUrl(),
        data: requestBody,
        options: Options(
          headers: headers,
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        // A sibling of `choices`, added by the worker rather than by OpenAI.
        // Read before the validity checks below so that a reply which arrived
        // but could not be used is still traceable to its log row.
        if (data is Map<String, dynamic> && data['log_id'] is String) {
          lastLogId = data['log_id'] as String;
        }
        if (data is Map<String, dynamic> && data['wallet'] is Map) {
          lastWallet = Map<String, dynamic>.from(data['wallet'] as Map);
        }
        final choices = data is Map<String, dynamic> ? data['choices'] : null;
        if (choices is! List || choices.isEmpty) {
          lastFailureReason = 'empty_response';
          return _thinkingTroubleMessage(debugDetail: _responseErrorMessage(data));
        }

        final firstChoice = choices.first;
        final messageData = firstChoice is Map<String, dynamic>
            ? firstChoice['message']
            : null;
        var responseText = messageData is Map<String, dynamic>
            ? messageData['content']
            : null;

        if (responseText is! String || responseText.trim().isEmpty) {
          lastFailureReason = 'empty_content';
          return _thinkingTroubleMessage(debugDetail: _responseErrorMessage(data));
        }

        // Clean up formatting
        responseText = responseText
            .replaceAll('**', '')
            .replaceAll('"', '')
            .replaceAll("'", '')
            .replaceAll('*', '')
            .trim();

        // Add assistant response to history
        _conversationHistory.add({
          "role": "assistant",
          "content": responseText,
        });

        lastSendSucceeded = true;
        return responseText;
      } else if (response.statusCode == 429) {
        lastFailureReason = 'rate_limited';
        return "I need a moment, darling. We've been talking so fast!";
      } else if (response.statusCode == 402) {
        // The tribute could not be afforded: the worker debited nothing and
        // called nobody. Not a reply and not the character's fault — the UI
        // reads lastWallet and explains. The user turn is rolled back out of
        // the model's history because, upstream, it never happened.
        lastFailureReason = 'insufficient_coins';
        final data = response.data;
        if (data is Map<String, dynamic> && data['wallet'] is Map) {
          lastWallet = Map<String, dynamic>.from(data['wallet'] as Map);
        }
        if (_conversationHistory.isNotEmpty &&
            _conversationHistory.last['role'] == 'user') {
          _conversationHistory.removeLast();
        }
        return "";
      } else {
        lastFailureReason = 'http_${response.statusCode}';
        return _thinkingTroubleMessage(debugDetail: _responseErrorMessage(response.data));
      }
    } catch (e) {
      // Never reached the worker, so nothing server-side recorded this send.
      lastFailureReason = 'network';
      if (kDebugMode) {
        debugPrint("Chat connection error: $e");
      }
      return _thinkingTroubleMessage();
    }
  }

  /// A friendly, in-character, vendor-agnostic message for any backend
  /// failure — the actual technical detail (which provider, what status)
  /// never reaches the chat UI; it only goes to the debug console (and,
  /// server-side, the admin log) so this stays diagnosable without ever
  /// showing a player a raw backend error.
  String _thinkingTroubleMessage({String? debugDetail}) {
    if (kDebugMode && debugDetail != null) {
      debugPrint("Chat backend error (hidden from user): $debugDetail");
    }
    return "$_characterDisplayName is having trouble thinking right now. Please stand by...";
  }

  String get _characterDisplayName {
    final scenario = _scenario;
    if (scenario == null || scenario.isEmpty) return "Your companion";
    final parenIndex = scenario.indexOf(' (');
    return parenIndex > 0 ? scenario.substring(0, parenIndex) : scenario;
  }

  Future<String> startRoleplay(String scenario) async {
    final contextMessage =
        "ACTION: The user has selected the roleplay scenario: '$scenario'. Adopt this persona immediately. Start with an immersive opening line that sets the scene. Do not break character.";
    return sendMessage(contextMessage);
  }

  String _responseErrorMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'];
        if (message != null) return message.toString();
      }
      if (error != null) return error.toString();
    }

    if (data != null) return data.toString();
    return "Unexpected empty response";
  }

  String _generateHmacSignature(String body, String timestamp) {
    final secret = AppConfig.appSecret;
    if (secret.isEmpty) return "";

    final key = utf8.encode(secret);
    final bytes = utf8.encode(body + timestamp);

    final hmacSha256 = Hmac(sha256, key);
    final digest = hmacSha256.convert(bytes);

    return digest.toString(); // Hex string
  }
}
