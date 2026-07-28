class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isSystem;

  /// Asset path when this message *is* an image — the character's portrait,
  /// "sent" as the opening of a new conversation. [text] is still set and is
  /// used as the accessibility label, so nothing that reads messages as
  /// strings (history, logging) has to know about images.
  final String? imageAsset;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.isSystem = false,
    this.imageAsset,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'isUser': isUser,
      'timestamp': timestamp.toIso8601String(),
      'isSystem': isSystem,
      if (imageAsset != null) 'imageAsset': imageAsset,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      text: json['text'] as String,
      isUser: json['isUser'] as bool,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isSystem: json['isSystem'] ?? false,
      imageAsset: json['imageAsset'] as String?,
    );
  }
}
