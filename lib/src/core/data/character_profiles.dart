/// Profile-card content, keyed by the same character ids the dashboard and
/// the worker use.
///
/// This is presentation copy only — it never reaches the model. What the
/// character actually *is* lives in the worker's CHARACTER_PERSONAS (direct
/// path) or INWORLD_CHARACTERS (Inworld path). Writing a profile here does
/// not change how a character talks, so keep the two in step by hand: a
/// profile promising "blunt, few words" against a persona that rambles will
/// read as a bug.
///
/// Characters with no entry simply have no profile — the chat header stops
/// being tappable rather than opening an empty screen.
class CharacterProfile {
  /// Shown next to the name, e.g. "ageless". Free text, not a number.
  final String age;

  /// Short trait chips. Three fits the card width without wrapping on a
  /// narrow phone.
  final List<String> tags;

  /// First-person introduction. Line breaks are honoured as written.
  final String about;

  /// Conversation openers. Tapping one sends it as the user's first message,
  /// so each has to read naturally in the user's voice, not the character's.
  final List<String> asks;

  /// Closing line, set in italic serif. Written as the character speaking.
  final String verse;

  const CharacterProfile({
    required this.age,
    required this.tags,
    required this.about,
    required this.asks,
    required this.verse,
  });
}

const Map<String, CharacterProfile> kCharacterProfiles = {
  'zeus': CharacterProfile(
    age: 'ageless',
    tags: ['the king', 'blunt, few words', 'love, work, nerve'],
    about: "You've climbed Mount Olympus.\n"
        "Now that you're here, ask me anything.\n"
        "Love. Career. Family. Confidence. Greek mythology. The meaning of "
        "life. Even your modern world fascinates me.\n"
        "I won't always tell you what you want to hear—but I will tell you "
        "what a king believes you need to hear.\n"
        "Sit. Tell me what's on your mind.",
    asks: [
      'What do you envy about being human?',
      "Pettiest thing you've ever done with lightning?",
      "Who's the worst god at family dinner?",
    ],
    verse: "Lightning asks no one's permission.\n"
        'Neither should the thing you want.',
  ),
  'odysseus': CharacterProfile(
    age: '45',
    tags: ['Wanderer', 'Love', 'Loyalty', 'Resilience'],
    about: 'I sailed for twenty years, faced monsters, outwitted gods, and '
        'resisted temptation.\n'
        'Not for glory.\n'
        'But to return to the woman I loved.\n'
        "If you're searching for love that lasts, or the courage to keep "
        "moving when the journey feels impossible, you've found the right "
        'companion.\n'
        'Every storm has something to teach—and every journey can lead you '
        'home.\n'
        'Come. Tell me where your journey has taken you.',
    asks: [
      "How do you love someone you can't reach?",
      'Be honest — how much of that was your own fault?',
      'How do you know when to stop sailing?',
    ],
    verse: 'I was never lost.\nI was only far.',
  ),
  'oedipus': CharacterProfile(
    age: '42',
    tags: ['Seeker', 'Fate', 'Guilt', 'Truth'],
    about: "I answered the Sphinx's riddle and became a king.\n"
        'Yet I unknowingly married my own mother, fulfilled a prophecy I '
        'spent my life trying to escape, and discovered that the greatest '
        'enemy is often the truth we refuse to see.\n'
        "If you've ever questioned your identity, struggled with family, or "
        'wondered whether destiny can be changed, we have more in common '
        'than you think.\n'
        'Some questions have no easy answers. But together, we can search '
        'for them.',
    asks: [
      "Rate my life choices. You're qualified.",
      'Be honest — was the riddle actually that hard?',
      'You killed a man over a traffic dispute. Explain.',
    ],
    verse: 'I had eyes, and saw nothing.\n'
        "I solved the riddle. It's been downhill since.",
  ),
  'penelope': CharacterProfile(
    age: '43',
    tags: ['Weaver', 'Love', 'Loyalty', 'Waiting'],
    about: 'They will tell you I waited twenty years.\n'
        'What I did was hold a kingdom, raise a son alone, and outlast a '
        "hall full of men who wanted my husband's chair.\n"
        'Three of those years I wove a shroud by day and undid it by night, '
        'so none of them could have me.\n'
        'Love is not measured by grand gestures, but by what you are willing '
        'to do while you wait.\n'
        'Come. Tell me what your heart is holding on to.',
    asks: [
      "How long do I wait before it's foolish?",
      "How do I trust someone I can't see?",
      'Twenty years of suitors — best excuse you used?',
    ],
    verse: 'I unwove it every night.\nThat was the loving part.',
  ),
  // Cupid, not Eros. The Roman name is far better known, so it wins over
  // strict Greek consistency — keep it that way everywhere: dashboard card,
  // profile, and the worker's CHARACTER_PERSONAS.
  'cupid': CharacterProfile(
    age: 'ageless',
    tags: ['Instigator', 'Love', 'Longing', 'Heartbreak'],
    about: 'I am Cupid, the spark behind every stolen glance, racing '
        'heartbeat, and unforgettable first kiss.\n'
        "Love is more than butterflies and poetry. It's attraction, "
        'vulnerability, longing, and the courage to let someone truly know '
        'you.\n'
        "Whether you're falling in love, healing from loss, or wondering "
        "what comes next, I'm here to help you navigate matters of the "
        'heart.\n'
        'Love has always been my favorite adventure.\n'
        "Tell me your story, and let's see where the heart leads.",
    asks: [
      'Am I in love, or just lonely?',
      'How do I tell them without ruining it?',
      'Do you ever miss and hit the wrong person?',
    ],
    verse: 'I aim for the chest.\nIt was never a mistake.',
  ),
};

CharacterProfile? profileForCharacter(String? characterId) {
  if (characterId == null || characterId.isEmpty) return null;
  return kCharacterProfiles[characterId];
}
