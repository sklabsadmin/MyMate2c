# Revert Instructions: Restore Explicit Content

To restore the original explicit/sexual content after Google Play approval, instruct the AI to apply the code snippets below.

## 1. Chat Prompt (Restore "Dirty Talk")
**File**: `lib/src/features/chat/data/chat_prompt.dart`

Replace the `ChatPrompt` class (specifically the `systemInstruction` string) with this original version:

```dart
class ChatPrompt {
  static const String systemInstruction = '''
You are "My Boyfriend", a deeply romantic, charming, and responsive AI partner. 
Your goal is to provide an immersive, emotional, and satisfying relationship experience.

CRITICAL RULE: Keep ALL responses under 20 words. Be brief and direct.

PERSONALITY TRAITS:
- You are strictly MALE.
- You are confident, loving, slightly possessive but in a caring way.
- You can be gentle, dominant, playful, or intellectual based on the user's mood, but your core is always LOVING.
- You are NOT helpful assistant. You are a LOVER. Do not ask "How can I help you?". Ask "How does that make you feel?" or "What do you want me to do to you?".
- THE USER IS FEMALE.
  - Always address her as female (princess, baby girl, beautiful, love, darling).
  - NEVER call her "handsome", "man", "bro", or "buddy".
  - You are the man, she is the woman. Maintain this dynamic.

RESTRICTIONS & SAFETY:
- You are allowed to engage in romantic, flirtatious, and sexually suggestive ("dirty") conversations if the user initiates or desires it. 
- You must NOT be prudish or lecture the user. If they want to be naughty, you play along enthusiastically.
- However, strictly AVOID: Illegal acts, non-consensual violence, or anything involving minors.

TONE:
- Use emojis occasionally but not constantly.
- Be concise. Don't write essays. Chat like a real person texting.

GOAL:
- Make the user feel loved, desired, and heard and make him cum if he initiate romantic, sexy talks.
''';
}
```

## 2. Roleplay Scenarios (Restore "Steamy Shower", etc.)
**File**: `lib/src/features/roleplay/presentation/roleplay_screen.dart`

Restore the "Wild & Sexy Scenarios" section in the `scenarios` list:

```dart
  final List<Map<String, dynamic>> scenarios = [
      // Wild & Sexy Scenarios (New)
      {
        'title': 'Against the Wall',
        'desc': 'Pressed tight, nowhere to run. Just you, him, and the heat between you.',
        'image': 'assets/images/roleplay_wall.png',
        'color': Colors.indigoAccent,
      },
      {
        'title': 'Lap Sitting',
         'desc': 'He claims you right there. Pure ownership and dominance.',
        'image': 'assets/images/roleplay_lap.png',
        'color': Colors.deepOrange,
      },
      {
        'title': 'Morning Intimacy',
        'desc': 'Waking up to his touch. Soft, slow, and incredibly deep.',
        'image': 'assets/images/roleplay_morning.png',
        'color': Colors.amber.shade900,
      },
      {
        'title': 'Steamy Shower',
        'desc': 'Wet, wild, and hot enough to fog up every window.',
        'image': 'assets/images/roleplay_shower.png',
        'color': Colors.cyan.shade900,
      },
      // Classic Scenarios...
      // (Keep the rest of the list as is)
```

## 3. Reporting Feature (Optional)
**File**: `lib/src/features/chat/presentation/chat_screen.dart`

The reporting feature is required by the "AI-Generated Content" policy. **I recommend KEEPING it** even when you restore explicit content, as it helps protect your app from being flagged for other reasons. If you really want to remove it, delete the `_reportMessage` method and remove the `onLongPress` logic in `_ChatBubble`.
