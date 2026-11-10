import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import 'leaderboard.dart';

/// The display name someone is listed under on the gift leaderboards, and
/// the rule that they have one before they give a gift.
///
/// The name IS the profile's Name field — one name, not two. What this adds
/// is the moment it becomes public: nothing typed into the profile is shown
/// to anyone until it has been sent to the worker from here, which happens
/// the first time they give a gift (and again whenever they change it
/// afterwards). The worker filters it and can refuse it.
///
/// [loadName] / [saveName] read and write the profile's name; they are
/// passed in so this file does not depend on how profiles are stored (and so
/// a test can stand in for them).
class LeaderboardNameGate {
  final LeaderboardService service;
  final Future<String> Function() loadName;
  final Future<void> Function(String name) saveName;

  LeaderboardNameGate({
    required this.service,
    required this.loadName,
    required this.saveName,
  });

  /// The name most recently accepted by the worker from this install. When
  /// it equals the profile name there is nothing to do before a gift.
  static const String sentKey = 'leaderboard_name_sent_v1';

  static const int minLength = 2;
  static const int maxLength = 20;

  /// Call before a gift is sent. True means go ahead.
  ///
  ///  - A name already on the leaderboards: straight through.
  ///  - A name in the profile that has not been sent yet: sent now, quietly —
  ///    they chose it, the profile says where it is shown, and asking again
  ///    is a prompt for nothing. Only if the worker refuses it are they asked
  ///    for another.
  ///  - No name: they are asked for one, and the gift waits on the answer.
  ///    "Not now" cancels the gift (false).
  ///
  /// The worker being unreachable never blocks a gift on its own account — a
  /// name they already have is retried next time. With no name at all there
  /// is nothing to retry, so the prompt stays up until it is sent or they
  /// back out; the gift needs the same network anyway.
  Future<bool> ensureBeforeGift(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final name = (await loadName()).trim();
    final sent = prefs.getString(sentKey);
    if (name.isNotEmpty && name == sent) return true;

    String? rejection;
    if (name.isNotEmpty) {
      final result = await service.setName(name);
      switch (result.outcome) {
        case NameOutcome.saved:
          await prefs.setString(sentKey, name);
          return true;
        case NameOutcome.disabled:
        case NameOutcome.unreachable:
          return true;
        case NameOutcome.rejected:
          rejection = result.reason;
      }
    }

    if (!context.mounted) return false;
    final chosen = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NameDialog(
        service: service,
        initial: name,
        initialRejection: rejection,
      ),
    );
    if (chosen == null) return false;
    // Empty means the worker said leaderboards are off: no name needed.
    if (chosen.isEmpty) return true;
    await saveName(chosen);
    await prefs.setString(sentKey, chosen);
    return true;
  }

  /// Call after the profile is saved with [name]. Keeps the leaderboards in
  /// step for someone who is already on them; does nothing for someone who
  /// has never given a gift (their name is still private). Returns a
  /// sentence to show when the new name was refused, otherwise null.
  Future<String?> afterProfileSaved(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final sent = prefs.getString(sentKey);
    final trimmed = name.trim();
    if (sent == null || trimmed.isEmpty || trimmed == sent) return null;
    final result = await service.setName(trimmed);
    if (result.outcome == NameOutcome.saved) {
      await prefs.setString(sentKey, trimmed);
      return null;
    }
    if (result.outcome == NameOutcome.rejected) {
      return 'Saved — but "$trimmed" cannot be shown on leaderboards, so '
          'they still show "$sent".';
    }
    return null;
  }
}

/// What to tell someone whose name the worker refused. Never says which
/// word: a filter that explains itself is a filter that gets worked around.
String leaderboardNameProblem(String? reason) => switch (reason) {
      'length' =>
        'Use between ${LeaderboardNameGate.minLength} and '
            '${LeaderboardNameGate.maxLength} characters.',
      'characters' =>
        'Use letters, numbers, spaces, hyphens and apostrophes only.',
      _ => 'That name cannot be used. Please choose another.',
    };

class _NameDialog extends StatefulWidget {
  final LeaderboardService service;
  final String initial;
  final String? initialRejection;

  const _NameDialog({
    required this.service,
    required this.initial,
    required this.initialRejection,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  late String? _error = widget.initial.isEmpty
      ? null
      : leaderboardNameProblem(widget.initialRejection);
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.characters.length < LeaderboardNameGate.minLength) {
      setState(() => _error = leaderboardNameProblem('length'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await widget.service.setName(name);
    if (!mounted) return;
    switch (result.outcome) {
      case NameOutcome.saved:
        Navigator.of(context).pop(result.name ?? name);
      case NameOutcome.disabled:
        Navigator.of(context).pop('');
      case NameOutcome.rejected:
        setState(() {
          _sending = false;
          _error = leaderboardNameProblem(result.reason);
        });
      case NameOutcome.unreachable:
        setState(() {
          _sending = false;
          _error = 'Could not reach the server. Please try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'Choose a display name',
        style: GoogleFonts.playfairDisplay(
          color: AppTheme.inkColor,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Gifts place you on the leaderboards. This is the name other '
            'people will see there, and what your companions will call you.',
            style: GoogleFonts.lato(
              color: AppTheme.mutedInkColor,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('leaderboard-name-field'),
            controller: _controller,
            autofocus: true,
            enabled: !_sending,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              LengthLimitingTextInputFormatter(LeaderboardNameGate.maxLength),
            ],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'Display name',
              errorText: _error,
              errorMaxLines: 3,
              filled: true,
              fillColor: AppTheme.panelColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You can change it any time in your profile.',
            style: GoogleFonts.lato(
              color: AppTheme.faintInkColor,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: _sending ? null : _submit,
          child: Text(_sending ? 'Saving…' : 'Continue'),
        ),
      ],
    );
  }
}
