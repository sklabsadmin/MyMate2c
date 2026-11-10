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
///
/// The worker can replace any of these, and supplies them for characters
/// added after this build (backend/src/catalogue.js, `nudges`).
const Map<String, List<String>> kBundledNudges = {
  'zeus': [
    'Olympus is quiet. I distrust quiet.',
    'A king notices an empty seat. Come and fill it.',
    'The thunder can wait. I would rather hear how your day went.',
  ],
  'odysseus': [
    'Calm seas tonight. Good weather for a story, if you have one.',
    'I have been thinking about harbours. Come and tell me about yours.',
    'Twenty years taught me to wait well. I am still glad when a sail appears.',
  ],
  'oedipus': [
    'I have a riddle for you, and for once it is not about me.',
    'Thebes sleeps. I rarely do. Come and keep an old king company.',
    'Some questions are better asked aloud. Bring me one.',
  ],
  'penelope': [
    'The loom is still tonight. I would rather have conversation.',
    'I know something about waiting. I also know when it is worth it.',
    'Come and sit. Tell me what your heart has been holding.',
  ],
  'calypso': [
    'The tide brought nothing interesting today. I was hoping for you.',
    'Ogygia is beautiful and very quiet. Come and make it less quiet.',
    'I let a sailor go once. I am better at welcomes than goodbyes.',
  ],
  'cupid': [
    'I have been behaving myself all day. It is exhausting. Come and talk.',
    'No arrows today, I promise. Just curiosity about how you are.',
    'Somebody caught your eye, or nobody did. Either way, I want to hear it.',
  ],
  'hector': [
    'The walls are quiet tonight. A good hour to talk.',
    'I have set the armour down for the evening. Tell me how you are holding up.',
    'A steady day is still a day worth telling. Come and tell me yours.',
  ],
  'andromache': [
    'The house is quiet. I thought of you and wondered how you are.',
    'Come and sit a while. You do not have to be strong here.',
    'I kept a place by the hearth. Tell me what today asked of you.',
  ],
  'hercules': [
    'Twelve labours, and the hardest thing is still an empty afternoon. Come talk.',
    'I have carried a lot. I would rather hear what you carried today.',
    'No monsters today. I am almost disappointed. How are you?',
  ],
  'badboy': [
    'Long ride, empty road. Thought of you. How have you been?',
    'I am not good at checking in. I am doing it anyway.',
    'Quiet night. Come and tell me what is going on with you.',
  ],
  'poet': [
    'I have half a line and no ending. Come and lend me your day.',
    'The page is blank tonight. I would rather listen than write.',
    'Something small and true happened to you today. Tell me what it was.',
  ],
  'surfer': [
    'Flat water today, dude. Good day for a talk instead.',
    'Sunset was unreal. Made me wonder how your day went.',
    'No swell till Thursday. Plenty of time to hear what is up with you.',
  ],
};

/// For a character with no lines of their own — one somebody created, or one
/// the worker added without any. Neutral enough to sit under any name.
const List<String> kGenericNudges = [
  'Come back when you can — I want to hear the rest.',
  'A quiet moment, and I wondered how you are.',
  'Tell me how today went.',
];

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
