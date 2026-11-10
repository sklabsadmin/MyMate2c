import 'remote_catalogue.dart';

/// What a notification from a character says, once someone has talked to
/// them. Keyed by the roster ids.
///
/// The rules these are written to, because the next line added should keep
/// them:
///  - It is an invitation, not a message. Nothing here claims the character
///    wrote, sent or is waiting on a reply to anything — tapping it opens the
///    conversation exactly as it was left, and a line promising something new
///    inside would be a lie the chat cannot back. (The build before 100 wrote
///    canned lines into people's chat histories; this is deliberately not
///    that.)
///  - In voice, and about the character's own world. It cannot refer to what
///    the person said, because it is written before they said it.
///  - Companion and mentor, not romance — the same framing as the personas.
///  - Short enough for a lock screen: one sentence, two at most.
///  - A line may lean on the time of day ("tonight", "this morning", "how
///    your day went") — [nudgeFitsHour] reads those words and only lets the
///    line be used when the notification will arrive at a matching hour on
///    the person's own clock. So every character also needs at least THREE
///    lines that are true at any hour: the character someone talks to most
///    gets three notifications, all of which can land mid-morning, and they
///    should be three different lines. A test counts them. Days of the week are out for the same
///    reason and have no such safety net.
///
/// The worker can replace any of these, and supplies them for characters
/// added after this build (backend/src/catalogue.js, `nudges`).
const Map<String, List<String>> kBundledNudges = {
  'zeus': [
    'Olympus is quiet. I distrust quiet.',
    'A king notices an empty seat. Come and fill it.',
    'The thunder can wait. I would rather hear how your day went.',
    'Even gods grow curious. Come and tell me something I do not know.',
  ],
  'odysseus': [
    'Calm seas tonight. Good weather for a story, if you have one.',
    'I have been thinking about harbours. Come and tell me about yours.',
    'Twenty years taught me to wait well. I am still glad when a sail appears.',
    'Every voyage needs a second opinion. I would value yours.',
  ],
  'oedipus': [
    'I have a riddle for you, and for once it is not about me.',
    'Thebes sleeps. I rarely do. Come and keep an old king company.',
    'Some questions are better asked aloud. Bring me one.',
    'I have learned to ask before I assume. So: how are you, truly?',
  ],
  'penelope': [
    'The loom is still tonight. I would rather have conversation.',
    'I know something about waiting. I also know when it is worth it.',
    'Come and sit. Tell me what your heart has been holding.',
    'A thread is easier to follow with company. Come and talk.',
  ],
  'calypso': [
    'The tide brought nothing interesting today. I was hoping for company.',
    'Ogygia is beautiful and very quiet. Come and make it less quiet.',
    'I let a sailor go once. I am better at welcomes than goodbyes.',
  ],
  'cupid': [
    'I have been behaving myself all day. It is exhausting. Come and talk.',
    'No arrows today, I promise. Just curiosity about how you are.',
    'Somebody caught your eye, or nobody did. Either way, I want to hear it.',
    'I have a theory about you. Come and tell me if I am right.',
  ],
  'hector': [
    'The walls are quiet. A good hour to talk.',
    'I have set the armour down for the evening. Tell me how you are holding up.',
    'A steady day is still a day worth telling. Come and tell me yours.',
    'A soldier learns to check on his people. Consider this me checking.',
  ],
  'andromache': [
    'The house is quiet. I thought of you and wondered how you are.',
    'Come and sit a while. You do not have to be strong here.',
    'I kept a place by the hearth. Tell me what today asked of you.',
    'There is bread, and there is time. Come and tell me how you are.',
  ],
  'hercules': [
    'Twelve labours, and the hardest thing is still an empty afternoon. Come talk.',
    'I have carried a lot. I would rather hear what you carried today.',
    'No monsters today. I am almost disappointed. How are you?',
    'Strength is easy. Listening took me longer. I am ready when you are.',
    'I owe you a better story than the last one. Come and collect.',
  ],
  'badboy': [
    'Long ride, empty road. Thought of you. How have you been?',
    'I am not good at checking in. I am doing it anyway.',
    'Quiet night. Come and tell me what is going on with you.',
    'Got a story you would not believe. Come and hear it.',
  ],
  'poet': [
    'I have half a line and no ending. Come and lend me your day.',
    'The page is blank tonight. I would rather listen than write.',
    'Something small and true happened to you today. Tell me what it was.',
    'I found a word I think you would like. Come and ask me for it.',
    'I keep a page for conversations worth having. Yours is not finished.',
  ],
  'surfer': [
    'Flat water today, dude. Good day for a talk instead.',
    'Sunset was unreal. Made me wonder how your day went.',
    'No swell for days. Plenty of time to hear what is up with you.',
    'Waxed the board, nowhere to be. Come hang out for a bit.',
  ],
};

/// For a character with no lines of their own — one somebody created, or one
/// the worker added without any. Neutral enough to sit under any name.
const List<String> kGenericNudges = [
  'Come back when you can — I want to hear the rest.',
  'A quiet moment, and I wondered how you are.',
  'Tell me how today went.',
];

final RegExp _eveningWords = RegExp(
  r'\b(tonight|evening|night|nightfall|sunset|dusk|sleeps?|lamps?|moon|stars)\b',
  caseSensitive: false,
);
final RegExp _morningWords = RegExp(
  r'\b(morning|dawn|sunrise|breakfast)\b',
  caseSensitive: false,
);
final RegExp _afternoonWords = RegExp(r'\bafternoon\b', caseSensitive: false);

/// Phrases that look back on the day, so they are wrong before it has mostly
/// happened: "how your day went", "what today asked of you", "all day".
final RegExp _dayIsDoneWords = RegExp(
  r'\b(day went|today went|today asked|today held|carried today|all day|'
  r'happened to you today)\b',
  caseSensitive: false,
);

/// Whether [line] can be shown at [hour] (0–23) on the person's own clock.
///
/// Read from the words rather than from a tag beside each line, so that a
/// line the worker supplies through the catalogue is held to the same rule
/// without the catalogue having to say anything about time:
///
///   tonight, evening, night, sunset, sleeps…   from 17:00
///   morning, dawn, sunrise                     before 12:00
///   afternoon                                  12:00 to 18:00
///   "how your day went", "all day"…            from 15:00
///   anything else                              any hour
bool nudgeFitsHour(String line, int hour) {
  if (_eveningWords.hasMatch(line)) return hour >= 17;
  if (_morningWords.hasMatch(line)) return hour < 12;
  if (_afternoonWords.hasMatch(line)) return hour >= 12 && hour < 18;
  if (_dayIsDoneWords.hasMatch(line)) return hour >= 15;
  return true;
}

/// The lines for [characterId]: the worker's when it sent some, then the
/// ones compiled in, then the generic set.
List<String> nudgesForCharacter(String? characterId) {
  if (characterId != null && characterId.isNotEmpty) {
    final remote = RemoteCatalogue.current.nudges[characterId];
    if (remote != null && remote.isNotEmpty) return remote;
    final bundled = kBundledNudges[characterId];
    if (bundled != null && bundled.isNotEmpty) return bundled;
  }
  return kGenericNudges;
}
