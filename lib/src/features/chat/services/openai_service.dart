import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/config/app_config.dart';
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

  Future<String> sendMessage(String message) async {
    lastSendSucceeded = false;
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
        final choices = data is Map<String, dynamic> ? data['choices'] : null;
        if (choices is! List || choices.isEmpty) {
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
        return "I need a moment, darling. We've been talking so fast!";
      } else {
        return _thinkingTroubleMessage(debugDetail: _responseErrorMessage(response.data));
      }
    } catch (e) {
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
