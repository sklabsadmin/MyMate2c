/// The player's own profile — who *they* are, as opposed to who a character
/// is (that lives server-side in the worker's CHARACTER_PERSONAS).
///
/// Every field is free text and every field is optional. Gender and pronouns
/// are deliberately not dropdowns: the worker's persona prompt says to assume
/// the user is female "unless they tell you what gender they want to be
/// referred to as", and a fixed list would decide that question for them.
///
/// Device-local only. Nothing here is sent to the worker yet — wiring it into
/// the chat request is a separate change, and `toPromptLines()` exists so that
/// when it is, the wording is defined in one place.
class UserProfile {
  /// What the characters should call them. Not necessarily a legal name — the
  /// field is free text and optional like the rest.
  final String name;
  final String age;
  final String gender;
  final String pronouns;
  final String location;
  final String hobbies;
  final String turnOns;

  /// Avatar. The two are mutually exclusive — setting one clears the other via
  /// [withPhoto]/[withEmoji] — so there is never a stored photo silently
  /// hiding behind a displayed emoji.
  ///
  /// [avatarPhoto] is a base64 data URI, downscaled at pick time. Neither is
  /// included in [toPromptLines]: an avatar is for the user to look at, not
  /// something to describe to the model.
  final String avatarEmoji;
  final String avatarPhoto;

  const UserProfile({
    this.name = '',
    this.age = '',
    this.gender = '',
    this.pronouns = '',
    this.location = '',
    this.hobbies = '',
    this.turnOns = '',
    this.avatarEmoji = '',
    this.avatarPhoto = '',
  });

  bool get hasAvatar => avatarPhoto.isNotEmpty || avatarEmoji.isNotEmpty;

  UserProfile withPhoto(String dataUri) =>
      copyWith(avatarPhoto: dataUri, avatarEmoji: '');

  UserProfile withEmoji(String emoji) =>
      copyWith(avatarEmoji: emoji, avatarPhoto: '');

  UserProfile withoutAvatar() => copyWith(avatarEmoji: '', avatarPhoto: '');

  static const UserProfile empty = UserProfile();

  bool get isEmpty =>
      name.isEmpty &&
      age.isEmpty &&
      gender.isEmpty &&
      pronouns.isEmpty &&
      location.isEmpty &&
      hobbies.isEmpty &&
      turnOns.isEmpty &&
      !hasAvatar;

  /// How many fields the user has actually filled in — drives the "3 of 7"
  /// hint on the profile screen. The avatar is deliberately not counted; it
  /// isn't one of the text fields the hint refers to.
  int get filledCount => [
        name,
        age,
        gender,
        pronouns,
        location,
        hobbies,
        turnOns,
      ].where((v) => v.trim().isNotEmpty).length;

  static const int fieldCount = 7;

  UserProfile copyWith({
    String? name,
    String? age,
    String? gender,
    String? pronouns,
    String? location,
    String? hobbies,
    String? turnOns,
    String? avatarEmoji,
    String? avatarPhoto,
  }) {
    return UserProfile(
      name: name ?? this.name,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      pronouns: pronouns ?? this.pronouns,
      location: location ?? this.location,
      hobbies: hobbies ?? this.hobbies,
      turnOns: turnOns ?? this.turnOns,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      avatarPhoto: avatarPhoto ?? this.avatarPhoto,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'age': age,
        'gender': gender,
        'pronouns': pronouns,
        'location': location,
        'hobbies': hobbies,
        'turnOns': turnOns,
        'avatarEmoji': avatarEmoji,
        'avatarPhoto': avatarPhoto,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    String read(String key) {
      final value = json[key];
      return value is String ? value : '';
    }

    return UserProfile(
      name: read('name'),
      age: read('age'),
      gender: read('gender'),
      pronouns: read('pronouns'),
      location: read('location'),
      hobbies: read('hobbies'),
      turnOns: read('turnOns'),
      avatarEmoji: read('avatarEmoji'),
      avatarPhoto: read('avatarPhoto'),
    );
  }

  /// Renders the filled-in fields as prompt lines. Empty fields are skipped
  /// rather than sent as blanks — "Location:" with nothing after it invites
  /// the model to invent one.
  List<String> toPromptLines() {
    final lines = <String>[];
    void add(String label, String value) {
      if (value.trim().isNotEmpty) lines.add('$label: ${value.trim()}');
    }

    add('Name', name);
    add('Age', age);
    add('Gender', gender);
    add('Refer to them using these pronouns', pronouns);
    add('Location', location);
    add('Hobbies and interests', hobbies);
    add('Turn ons', turnOns);
    return lines;
  }
}
