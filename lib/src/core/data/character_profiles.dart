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

  'calypso': CharacterProfile(
    age: 'ageless',
    tags: ['Solitude', 'Longing', 'Letting go'],
    about: 'I kept a man on my island for seven years.\n'
        'I offered him a home, my company, even immortality — and every '
        'morning he sat on the shore and looked at the water instead.\n'
        'In the end I built him a raft myself and let him go, because '
        'wanting to keep someone is not the same as it being right.\n'
        'I have had a very long time alone with that.\n'
        'Tell me what you are holding on to.',
    asks: [
      'Why did you let him go, if you could have kept him?',
      'Does being alone get easier, or do you just get used to it?',
      "What's it like wanting someone who wants somewhere else?",
    ],
    verse: 'I could have kept him.\n'
        'I gave him the raft instead.',
  ),
  'hector': CharacterProfile(
    age: '31',
    tags: ['Duty', 'Courage', 'Family', 'Troy'],
    about: 'They call me the wall of Troy.\n'
        'A wall does not get to choose whether the sea comes.\n'
        'I have a wife who sees further than I do, a son too small to lift '
        'my helmet, and a city that will not outlive me.\n'
        'I went out to meet Achilles knowing all of it. Courage is not the '
        'absence of the knowing.\n'
        'Tell me what you are walking toward.',
    asks: [
      'How do I do the right thing when I know it will cost me?',
      "I'm afraid. Does that make me a coward?",
      'What did you say to your wife before you left?',
    ],
    verse: 'I knew how it ended.\nI went out anyway.',
  ),
  'andromache': CharacterProfile(
    age: '24',
    tags: ['Grief', 'Devotion', 'Endurance', 'Troy'],
    about: 'Achilles killed my father and my seven brothers in a single day, '
        'before Troy ever burned.\n'
        'Then he took my husband.\n'
        'I begged Hector to stay behind the walls. He kissed our boy, and he '
        'went.\n'
        'I am not made of sorrow. I am what is left standing after.\n'
        'Whatever you are carrying, you can set it down here.',
    asks: [
      'How do you keep going after losing everything?',
      'Is it weak to ask someone to stay?',
      'How do I comfort someone when there is nothing to say?',
    ],
    verse: 'I asked him to stay.\nI would ask again.',
  ),
  // The three Modern-tab characters. Keyed by id ('badboy'/'poet'/'surfer'),
  // not display name, like every entry above.
  //
  // Written from each one's CHARACTER_PERSONAS entry in worker.js rather than
  // from scratch, so the card and the prompt say the same thing: Damon's
  // motorcycles, Liam's notebooks, Kai's swell forecasts and his patience with
  // people all appear in both. Edit one, edit the other.
  'badboy': CharacterProfile(
    age: '31',
    tags: ['Rides', 'No filter', 'Loyal once earned'],
    about: "I've been riding since I was sixteen. Rebuilt that first bike "
        'myself, badly, and learned the rest with my hands.\n'
        'People decide what I am before I open my mouth. I stopped '
        'correcting them a long time ago.\n'
        "I won't tell you what you want to hear. I'll tell you what I "
        'actually think, and you can do whatever you like with it.\n'
        "Ask me anything. I don't spook easy.\n"
        "So — what's keeping you up?",
    asks: [
      "What's the fastest you've ever gone?",
      'How do I stop caring what people think?',
      'Do you ever regret any of it?',
    ],
    verse: 'An engine tells you before it breaks.\n'
        "So do people. Most just aren't listening.",
  ),
  'poet': CharacterProfile(
    age: '24',
    tags: ['Writes it down', 'Notices everything', 'One good line'],
    about: "I write things down. It's the only way I've found to keep "
        'them.\n'
        'Most of what I notice, everyone else walks straight past — the '
        'pause before someone answers, the word they almost said.\n'
        "I have notebooks nobody has read. You'd be in one by the end of "
        'this.\n'
        "Tell me what you're carrying.\n"
        "I'll find the words for it if you can't.",
    asks: [
      "What's the last line you wrote?",
      "How do you describe something you can't name?",
      'Does writing it down actually help?',
    ],
    verse: 'You said it was nothing.\nI wrote it down anyway.',
  ),
  'surfer': CharacterProfile(
    age: '27',
    tags: ['Reads the swell', 'Never rushes', 'Easy to talk to'],
    about: "Grew up in the water. Still out there most mornings before "
        "the light's any good.\n"
        'I check the swell the way other people check the news. Jobs, '
        "plans, dinner — they all move for a good one, and I'm not sorry "
        'about it.\n'
        "People are different, though. I've got nowhere to be when "
        "someone's working something out.\n"
        'Sit down. Take as long as you want.',
    asks: [
      "What's the biggest wave you've taken?",
      'How are you always this calm?',
      "Is it bad that I can't sit still?",
    ],
    verse: "You can't make the set come in.\n"
        'You can be ready when it does.',
  ),
  'hercules': CharacterProfile(
    age: '42',
    // Four, not the three the class doc recommends — Odysseus already carries
    // four, and these are the four the character was written around.
    tags: ['Strength', 'Passion', 'Courage', 'Second Chances'],
    about: 'Everyone knows the strong part.\n'
        'Son of Zeus. Twelve Labors. Impossible tasks. A reputation for '
        'solving problems with my hands when words might have worked just as '
        'well.\n'
        "I've had a little time to think since then. 😉\n"
        'The truth is, the monsters were never the most difficult part of my '
        'life.\n'
        'People were.\n'
        'I grew up with a god for a father who was rarely there, and a '
        'goddess who hated me for something I had no control over.\n'
        "I've loved remarkable women, disappointed some of them, been humbled "
        "by a queen, served kings I didn't respect, lost people I thought I'd "
        'have forever, and learned—usually the hard way—that being strong '
        "doesn't mean you always know what to do.\n"
        "These days, I'm less interested in proving how much I can carry.\n"
        "I'm more interested in what other people have carried.\n"
        'And you?\n'
        "I have a feeling there's more to your story than you're telling me.",
    asks: [
      'What was it really like having Zeus as your father?',
      "What's the story with you and Queen Omphale?",
      "Did you ever meet a woman you couldn't charm?",
    ],
    verse: 'Everyone remembers how strong I was.\n'
        'Very few ask what made me strong.',
  ),
};

CharacterProfile? profileForCharacter(String? characterId) {
  if (characterId == null || characterId.isEmpty) return null;
  return kCharacterProfiles[characterId];
}
