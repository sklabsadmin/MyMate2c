import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/models/user_profile.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/profile_sync_service.dart';
import '../../../core/services/storage_service.dart';

/// "My Profile" — the player's own details, reached from the bottom nav.
///
/// Distinct from the *character* profile screen (character_profile_screen.dart),
/// which shows who Zeus or Penelope is. This one is about the user.
///
/// Everything is optional free text. Gender and pronouns are text fields with
/// tap-to-fill suggestions rather than dropdowns — a fixed list would decide
/// the question for the user, and the character personas are written to follow
/// whatever the user says rather than assume.
class UserProfileScreen extends ConsumerStatefulWidget {
  const UserProfileScreen({super.key});

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _gender = TextEditingController();
  final _pronouns = TextEditingController();
  final _location = TextEditingController();
  final _hobbies = TextEditingController();
  final _turnOns = TextEditingController();

  bool _loading = true;
  bool _dirty = false;

  /// Offer Google sign-in at most once per visit, so repeated saves don't nag.
  bool _signInSuggested = false;

  String _avatarEmoji = '';
  String _avatarPhoto = '';

  /// Deliberately a small, curated set rather than a full emoji keyboard —
  /// this is an avatar, and a scrollable wall of every emoji makes choosing
  /// one harder, not easier.
  static const List<String> _emojiChoices = [
    '😊', '😎', '🥰', '😇', '🤠', '🦊',
    '🐱', '🐼', '🦋', '🌙', '⭐', '🔥',
    '🌊', '🌸', '🍀', '☕', '🎧', '📚',
    '🎨', '⚡', '💫', '🖤', '💜', '🌹',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageServiceProvider);
    var profile = await storage.loadUserProfile();

    // Signed-in users get the server copy, so a profile written on another
    // device wins over whatever this one happens to have cached. Returns null
    // when signed out or unreachable, in which case the local copy stands.
    final remote = await ref.read(profileSyncServiceProvider).fetch();
    if (remote != null && !remote.isEmpty) {
      profile = remote;
      await storage.saveUserProfile(remote);
    }

    if (!mounted) return;
    _name.text = profile.name;
    _age.text = profile.age;
    _gender.text = profile.gender;
    _pronouns.text = profile.pronouns;
    _location.text = profile.location;
    _hobbies.text = profile.hobbies;
    _turnOns.text = profile.turnOns;
    _avatarEmoji = profile.avatarEmoji;
    _avatarPhoto = profile.avatarPhoto;
    for (final c in _controllers) {
      c.addListener(_markDirty);
    }
    setState(() => _loading = false);
  }

  Future<void> _pickPhoto() async {
    try {
      // Downscaled at pick time, not after: the raw file from a phone camera
      // is several megabytes, and it gets base64'd into SharedPreferences.
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _avatarPhoto = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        _avatarEmoji = '';
        _dirty = true;
      });
    } catch (e, stack) {
      // Log the real reason: a bare snackbar makes this failure impossible to
      // diagnose, which is exactly what happened the first time it broke.
      debugPrint('Avatar photo pick failed: $e');
      debugPrint('$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open your photos: $e")),
      );
    }
  }

  Future<void> _pickEmoji() async {
    final theme = Theme.of(context);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pick an emoji',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final e in _emojiChoices)
                      InkWell(
                        borderRadius: BorderRadius.circular(30),
                        onTap: () => Navigator.of(sheetContext).pop(e),
                        child: Container(
                          width: 52,
                          height: 52,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.05),
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (chosen == null || !mounted) return;
    setState(() {
      _avatarEmoji = chosen;
      _avatarPhoto = '';
      _dirty = true;
    });
  }

  void _removeAvatar() {
    setState(() {
      _avatarEmoji = '';
      _avatarPhoto = '';
      _dirty = true;
    });
  }

  List<TextEditingController> get _controllers =>
      [_name, _age, _gender, _pronouns, _location, _hobbies, _turnOns];

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  UserProfile get _current => UserProfile(
        name: _name.text,
        age: _age.text,
        gender: _gender.text,
        pronouns: _pronouns.text,
        location: _location.text,
        hobbies: _hobbies.text,
        turnOns: _turnOns.text,
        avatarEmoji: _avatarEmoji,
        avatarPhoto: _avatarPhoto,
      );

  Future<void> _save() async {
    // Always save locally first. The sign-in suggestion below is an offer, not
    // a gate — a signed-out user who declines still keeps their profile.
    await ref.read(storageServiceProvider).saveUserProfile(_current);
    if (!mounted) return;
    setState(() => _dirty = false);

    final authed = ref.read(authProvider).value?.authenticated ?? false;
    if (!authed) {
      if (!_signInSuggested) {
        _signInSuggested = true;
        await _suggestSignIn();
        return;
      }
      _toast('Saved on this device');
      return;
    }

    // Signed in: push to the worker, keyed server-side to the Google account.
    final synced = await ref.read(profileSyncServiceProvider).push(_current);
    if (!mounted) return;
    _toast(synced
        ? 'Profile saved to your account'
        : 'Saved on this device — could not reach your account');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Offered once per visit to the screen, after a signed-out user saves.
  ///
  /// A profile kept only in SharedPreferences dies with the browser cache and
  /// doesn't follow the user to another device. Google sign-in is what makes
  /// it portable, because linked_accounts gives a stable identifier for the
  /// same person across devices — an anonymous `user_<timestamp>` does not.
  Future<void> _suggestSignIn() async {
    final theme = Theme.of(context);
    final signIn = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Saved on this device',
                style:
                    theme.textTheme.titleMedium?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                'Sign in with Google to keep your profile if you clear your '
                'browser, and to have it follow you to your phone.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  child: const Text(
                    'Continue with Google',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: const Text(
                    'Not now',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (signIn != true || !mounted) return;
    await _launchGoogleAuth();
  }

  Future<void> _launchGoogleAuth() async {
    final returnTo = Uri.base.toString();
    final prefs = await SharedPreferences.getInstance();
    final anonId = prefs.getString('user_id');
    final authUrl = AppConfig.googleAuthUrl(returnTo, anonId: anonId);
    if (authUrl.isEmpty) return;
    // Same-tab navigation so the browser keeps the user-gesture context and
    // doesn't popup-block the OAuth redirect. Mirrors chat_screen's login gate.
    await launchUrl(Uri.parse(authUrl), webOnlyWindowName: '_self');
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_markDirty);
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final filled = _current.filledCount;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Text(
              'My Profile',
              style: theme.textTheme.displayLarge
                  ?.copyWith(fontSize: 28, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              filled == 0
                  ? 'Tell your companions about you. Every field is optional.'
                  : '$filled of ${UserProfile.fieldCount} filled in. Every field is optional.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 20),
            _avatarSection(theme),
            const SizedBox(height: 24),
            _field(
              theme,
              label: 'Name',
              controller: _name,
              hint: 'What should they call you?',
            ),
            _field(theme, label: 'Age', controller: _age, hint: 'e.g. 29'),
            _field(
              theme,
              label: 'Gender',
              controller: _gender,
              hint: 'However you describe yourself',
              suggestions: const ['Woman', 'Man', 'Non-binary'],
            ),
            _field(
              theme,
              label: 'Preferred pronouns',
              controller: _pronouns,
              hint: 'How you want to be referred to',
              suggestions: const ['she/her', 'he/him', 'they/them'],
            ),
            _field(
              theme,
              label: 'Location',
              controller: _location,
              hint: 'City, country, or just a vibe',
            ),
            _field(
              theme,
              label: 'Hobbies and interests',
              controller: _hobbies,
              hint: 'What you spend your time on',
              maxLines: 3,
            ),
            _field(
              theme,
              label: 'Turn ons',
              controller: _turnOns,
              hint: 'What you find attractive',
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Text(
              'Saved on this device only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white38,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _dirty ? _save : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  disabledBackgroundColor: Colors.white12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                child: Text(
                  _dirty ? 'Save' : 'Saved',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarSection(ThemeData theme) {
    final hasPhoto = _avatarPhoto.isNotEmpty;
    final hasEmoji = _avatarEmoji.isNotEmpty;

    Widget avatarContent;
    if (hasPhoto) {
      avatarContent = ClipOval(
        child: Image.memory(
          base64Decode(_avatarPhoto.split(',').last),
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          // A corrupt or truncated stored value shouldn't blank the screen.
          errorBuilder: (_, _, _) =>
              const Icon(Icons.person, size: 44, color: Colors.white24),
        ),
      );
    } else if (hasEmoji) {
      avatarContent = Text(_avatarEmoji, style: const TextStyle(fontSize: 44));
    } else {
      avatarContent =
          const Icon(Icons.person_outline, size: 44, color: Colors.white24);
    }

    return Center(
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.05),
              border: Border.all(
                color: _current.hasAvatar
                    ? theme.primaryColor.withOpacity(0.5)
                    : Colors.white.withOpacity(0.08),
                width: 2,
              ),
            ),
            child: avatarContent,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _avatarButton(
                theme,
                icon: Icons.photo_camera_outlined,
                label: hasPhoto ? 'Change photo' : 'Upload photo',
                onTap: _pickPhoto,
              ),
              _avatarButton(
                theme,
                icon: Icons.emoji_emotions_outlined,
                label: hasEmoji ? 'Change emoji' : 'Pick an emoji',
                onTap: _pickEmoji,
              ),
              if (_current.hasAvatar)
                _avatarButton(
                  theme,
                  icon: Icons.close,
                  label: 'Remove',
                  onTap: _removeAvatar,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _avatarButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: Colors.white70),
      label: Text(
        label,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
      style: TextButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.05),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
      ),
    );
  }

  Widget _field(
    ThemeData theme, {
    required String label,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    List<String> suggestions = const [],
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label and its suggestion chips share one row. A Wrap rather than a
          // Row so a narrow phone drops the chips onto a second line instead of
          // overflowing — the chips used to sit under the field, which cost a
          // whole extra row of height on every field that had them.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final s in suggestions)
                _suggestionChip(theme, s, controller),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: theme.primaryColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact tap-to-fill chip, sized to sit on the label row rather than under
  /// the field. Default ActionChip padding and tap-target sizing make it too
  /// tall for that, hence the shrinkWrap and explicit density.
  Widget _suggestionChip(
    ThemeData theme,
    String value,
    TextEditingController controller,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        controller.text = value;
        _markDirty();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.white.withOpacity(0.05),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Text(
          value,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ),
    );
  }
}
