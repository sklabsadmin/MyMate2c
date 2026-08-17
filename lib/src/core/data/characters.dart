import 'package:flutter/material.dart';

/// The built-in character roster, keyed by the same ids the dashboard, the
/// profile cards and the worker all use.
///
/// Lives here rather than inside the dashboard's State so that routes can
/// resolve a character by id without building the dashboard — deep links like
/// /c/zeus need name/vibe/image before any screen exists.
///
/// Presentation only. What a character actually *is* comes from the worker's
/// CHARACTER_PERSONAS (direct path) or INWORLD_CHARACTERS (Inworld path);
/// nothing here reaches the model. The 'engine' field, where present, is local
/// documentation of that server-side choice, not something sent to the backend.
///
/// Which of these appear, and in what order, is AppConfig.visibleCharacterIds
/// and the greek/modern group lists — an entry here is not automatically shown.
const List<Map<String, dynamic>> kCharacters = [
    {
      'id': 'ceo',
      'name': 'Christian',
      'vibe': 'The CEO',
      'desc': 'Dominant, wealthy, and possessive.',
      'image': 'assets/images/avatar_ceo_real.jpg', 
      'color': const Color(0xFF1A237E),
    },
    {
      'id': 'badboy',
      'name': 'Damon',
      'vibe': 'Bad Boy',
      'desc': 'Rebellious, passionate, and dangerous.',
      'image': 'assets/images/avatar_badboy_real.jpg',
      'color': const Color(0xFFB71C1C),
    },
    {
      'id': 'artist',
      'name': 'Julian',
      'vibe': 'The Artist',
      'desc': 'Sensitive, romantic, and attentive.',
      'image': 'assets/images/avatar_artist_real.jpg',
      'color': const Color(0xFF4A148C),
    },
    // New Boyfriends
    {
      'id': 'architect',
      'name': 'Adrian',
      'vibe': 'Architect',
      'desc': 'Structured, visionary, and builds a future with you.',
      'image': 'assets/images/avatar_architect_real.jpg', 
      'color': Colors.teal,
    },
    {
      'id': 'rockstar',
      'name': 'Jax',
      'vibe': 'Rockstar',
      'desc': 'Wild concerts, late nights, and songs about you.',
      'image': 'assets/images/avatar_rockstar_real.jpg', 
      'color': Colors.purpleAccent,
    },
    {
      'id': 'chef',
      'name': 'Marco',
      'vibe': 'The Chef',
      'desc': 'Passionate, fiery, and knows how to taste.',
      'image': 'assets/images/avatar_chef_real.jpg', 
      'color': Colors.orange,
    },
    {
      'id': 'doctor',
      'name': 'Dr. Ethan',
      'vibe': 'The Doctor',
      'desc': 'Intelligent, caring, and knows anatomy well.',
      'image': 'assets/images/avatar_doctor_real.jpg', 
      'color': Colors.cyan,
    },
    {
      'id': 'pilot',
      'name': 'Captain Ryker',
      'vibe': 'The Pilot',
      'desc': 'Adventure, uniforms, and taking you to new heights.',
      'image': 'assets/images/avatar_pilot_real.jpg', 
      'color': Colors.indigo,
    },
    {
      'id': 'biker',
      'name': 'Spike',
      'vibe': 'Biker',
      'desc': 'Leather, chrome, and the open road.',
      'image': 'assets/images/avatar_biker_real.jpg', 
      'color': Colors.grey,
    },
    {
      'id': 'poet',
      'name': 'Liam',
      'vibe': 'The Poet',
      'desc': 'Words are his weapon, and he writes them for you.',
      'image': 'assets/images/avatar_poet_real.jpg', 
      'color': Colors.brown,
    },
    {
      'id': 'vampire',
      'name': 'Lucien',
      'vibe': 'Vampire',
      'desc': 'Eternal love, dark secrets, and a dangerous bite.',
      'image': 'assets/images/avatar_vampire_real.jpg', 
      'color': Colors.red,
    },
    {
      'id': 'guard',
      'name': 'Silas',
      'vibe': 'Bodyguard',
      'desc': 'He fails at nothing, especially protecting you.',
      'image': 'assets/images/avatar_bodyguard_real.jpg', 
      'color': Colors.black,
    },
    {
      'id': 'zeus',
      'name': 'Zeus',
      'vibe': 'Olympian King',
      'desc': "Regal, magnetic. He'll tell you what you need to hear.",
      'image': 'assets/images/avatar_zeus_real.jpg',
      'color': Colors.amber,
    },
    {
      'id': 'surfer',
      'name': 'Kai',
      'vibe': 'Surfer',
      'desc': 'Sun, salt, and endless chill vibes.',
      'image': 'assets/images/custom_avatar_02.jpg',
      'color': Colors.cyanAccent,
    },
    // Imported from SKLabChat. Odysseus used to run on Inworld too; he now
    // uses the direct-OpenAI path like everyone else, leaving Oedipus as the
    // only Inworld character. The worker decides the engine from 'id'; the
    // 'engine' field below is local documentation of that choice, not
    // something sent to the backend.
    {
      'id': 'odysseus',
      'name': 'Odysseus',
      'vibe': 'King of Ithaca',
      'desc': 'A strategist, wanderer, and survivor who speaks with cunning and hard-earned wisdom.',
      'image': 'assets/images/avatar_odysseus_real.jpg',
      'color': const Color(0xFF9D4F2F),
    },
    {
      'id': 'oedipus',
      'name': 'Oedipus',
      'vibe': 'King of Thebes',
      'desc': 'A tragic king carrying prophecy, pride, grief, and hard-won self-knowledge.',
      'image': 'assets/images/avatar_oedipus_real.jpg',
      'color': const Color(0xFF7D3F25),
      'engine': 'inworld',
    },
    // These two run on the default direct-OpenAI path (no INWORLD_CHARACTERS
    // entry in the worker), so their persona comes from CHARACTER_PERSONAS
    // in backend/src/worker.js rather than from the fields here.
    {
      'id': 'penelope',
      'name': 'Penelope',
      'vibe': 'Queen of Ithaca',
      'desc': 'Patient, sharp-witted, and unbreakably loyal through twenty years of waiting.',
      'image': 'assets/images/avatar_penelope_real.jpg',
      'color': const Color(0xFF6A4C93),
    },
    {
      'id': 'calypso',
      'name': 'Calypso',
      'vibe': 'Nymph of Ogygia',
      'desc': 'Kept Odysseus seven years, offered him immortality, and let him go anyway.',
      'image': 'assets/images/avatar_calypso_real.jpg',
      'color': const Color(0xFF2E7D8F),
    },
    {
      'id': 'cupid',
      'name': 'Cupid',
      'vibe': 'God of Desire',
      'desc': 'Mischievous and disarming, with an aim no mortal heart survives.',
      // 4:3 rather than the square every other portrait uses; the card
      // crops with BoxFit.cover, so the sides are trimmed rather than
      // letterboxed.
      'image': 'assets/images/avatar_cupid_real.jpg',
      'color': const Color(0xFFD81B60),
    },
    {
      'id': 'hector',
      'name': 'Hector',
      'vibe': 'Prince of Troy',
      'desc': "Troy's greatest defender — steady, plain-spoken, and gentlest with those he loves.",
      'image': 'assets/images/avatar_hector_real.jpg',
      'color': const Color(0xFFB03A2E),
    },
    {
      'id': 'andromache',
      'name': 'Andromache',
      'vibe': 'Lady of Troy',
      'desc': 'Gentle and clear-eyed, carrying quiet strength through everything war took.',
      'image': 'assets/images/avatar_andromache_real.jpg',
      'color': const Color(0xFF8E6C9B),
    },
    {
      'id': 'hercules',
      'name': 'Hercules',
      'vibe': 'Son of Zeus',
      'desc': 'Strongest man alive, and far more interested in what you have carried than in what he lifted.',
      // One line under the title on the entry card, where 'desc' is too long to
      // sit. Optional: a character without it simply has no third line, which
      // is why nobody else needed touching to add this. Hercules is currently
      // the only one who has it, so his entry card is a line richer than
      // everyone else's until the rest are written.
      'tagline': 'Strongest Mortal and Hero of Olympus.',
      // Square, like every other avatar here, and cropped from the top of the
      // supplied full-body portrait rather than its centre. The circular
      // avatars (chat header, entry card) use BoxFit.cover, which centre-crops
      // — and the centre of that portrait is his waist, so the source image
      // used as delivered showed a headless torso.
      'image': 'assets/images/avatar_hercules_real.jpg',
      'color': const Color(0xFF8C5A2B),
    },
];

/// The roster entry for [characterId], or null when there is no such
/// character. Callers decide what an unknown id means: the deep-link route
/// sends it to the dashboard rather than erroring.
Map<String, dynamic>? characterById(String? characterId) {
  if (characterId == null || characterId.isEmpty) return null;
  for (final character in kCharacters) {
    if (character['id'] == characterId) return character;
  }
  return null;
}
