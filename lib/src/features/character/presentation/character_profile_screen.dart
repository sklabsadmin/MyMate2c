import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/data/character_profiles.dart';
import '../../../core/presentation/clear_history_prompt.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../wallet/coin_wallet.dart';
import '../../wallet/presentation/coins_sheet.dart';

/// Character profile card, opened from the chat header.
///
/// Pops with the tapped "Ask Me About" question as its result, or null if the
/// user just backed out — the chat screen sends whatever comes back. Keeping
/// the send in the chat screen means this widget owns no chat state.
class CharacterProfileScreen extends ConsumerWidget {
  final String name;
  final String title;
  final String imagePath;
  final CharacterProfile profile;

  /// Keys for the hidden Tab-to-clear prompt. [chatId] is the scenario
  /// string messages are stored under; [characterKey] is the character id the
  /// free-reply counter uses. Omit them and the shortcut is inert.
  final String? chatId;
  final String? characterKey;

  const CharacterProfileScreen({
    super.key,
    required this.name,
    required this.title,
    required this.imagePath,
    required this.profile,
    this.chatId,
    this.characterKey,
  });

  /// Tab clears this character's locally cached conversation only. Nothing
  /// server-side is touched, and other characters are left alone.
  Future<void> _promptClear(BuildContext context, WidgetRef ref) async {
    final id = chatId;
    final key = characterKey;
    if (id == null || key == null) return;

    final confirmed = await showClearHistoryPrompt(
      context,
      message: 'Do you want your chat history with $name cleared?',
    );
    if (!confirmed || !context.mounted) return;

    await ref
        .read(storageServiceProvider)
        .clearChatHistoryFor(chatId: id, characterKey: key);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Chat history with $name cleared on this device.')),
    );
  }

  // The profile is a moment of stillness away from the chat, and should read
  // closer to a museum label than a messaging UI: navy-plum ink on white
  // paper, fine rules, and the verse in gold. Mapped onto the app's light
  // palette so the card sits with the rest of the white theme.
  static const _bg = Colors.white;
  static const _ink = AppTheme.inkColor;
  static const _gold = AppTheme.goldInkColor;
  static const _muted = AppTheme.mutedInkColor;
  static const _body = AppTheme.mutedInkColor;
  static const _chip = AppTheme.panelColor;
  static const _chipInk = AppTheme.inkColor;
  static const _rule = AppTheme.hairlineColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.tab) {
          _promptClear(context, ref);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildScaffold(context, ref),
    );
  }

  Widget _buildScaffold(BuildContext context, WidgetRef ref) {
    // The keepsakes this person gave this character. Read from the wallet the
    // app already holds, so an unpriced or disabled wallet simply shows none.
    final keepsakes =
        ref.watch(coinWalletProvider).value?.keepsakesFor(characterKey) ??
            const <Keepsake>[];
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Stack(
              children: [
                ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Image.asset(imagePath, fit: BoxFit.cover),
                      ),
                    ),
                    Container(
                      decoration: const BoxDecoration(
                        color: _bg,
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(12),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  style: GoogleFonts.outfit(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                    color: _ink,
                                  ),
                                ),
                              ),
                              if (profile.age.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  profile.age,
                                  style: GoogleFonts.outfit(
                                    fontSize: 15,
                                    color: _muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            title,
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              color: _muted,
                            ),
                          ),
                          // Trait chips sit at the end of About Me rather than
                          // under the title: they read as a summary of what
                          // was just said, instead of a label the reader has
                          // to interpret before there is any context for it.
                          _section(
                            'About Me',
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  profile.about,
                                  style: GoogleFonts.outfit(
                                    fontSize: 13,
                                    height: 1.7,
                                    color: _body,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final tag in profile.tags)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _chip,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          tag,
                                          style: GoogleFonts.outfit(
                                            fontSize: 11,
                                            color: _chipInk,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // In the character's voice, like the sections
                          // around it. Only there once something was given:
                          // an empty "Gifts From You" would read as a hint.
                          if (keepsakes.isNotEmpty)
                            _section(
                              'Gifts From You',
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final k in keepsakes)
                                    _KeepsakeRow(keepsake: k, characterName: name),
                                ],
                              ),
                            ),
                          _section(
                            'Ask Me About',
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final ask in profile.asks)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: _AskButton(
                                      label: ask,
                                      onTap: () =>
                                          Navigator.of(context).pop(ask),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.only(top: 16),
                            padding: const EdgeInsets.only(top: 14),
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: _rule, width: 0.5),
                              ),
                            ),
                            child: Text(
                              profile.verse,
                              style: GoogleFonts.cormorantGaramond(
                                fontSize: 16,
                                height: 1.5,
                                fontStyle: FontStyle.italic,
                                color: _gold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Floats over the artwork rather than sitting in an app bar,
                // so the image stays full-bleed at the top of the card.
                Positioned(
                  top: 8,
                  left: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String label, Widget child) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.only(top: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _rule, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              color: _ink,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _AskButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AskButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(
              color: CharacterProfileScreen._rule,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 12,
              color: CharacterProfileScreen._chipInk,
            ),
          ),
        ),
      ),
    );
  }
}

/// One keepsake on the profile: the painted gift, its name, and when it was
/// given ("Golden Laurel for Penelope · Given 5 Oct 2026").
class _KeepsakeRow extends StatelessWidget {
  final Keepsake keepsake;
  final String characterName;

  const _KeepsakeRow({required this.keepsake, required this.characterName});

  @override
  Widget build(BuildContext context) {
    final option =
        kTributeOptions.where((o) => o.item == keepsake.item).firstOrNull;
    final given = keepsake.givenAt;
    final when = given == null
        ? (option?.heldDetail ?? '')
        : 'Given ${DateFormat('d MMM y').format(given.toLocal())}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: option == null
                ? const Icon(Icons.card_giftcard,
                    size: 22, color: CharacterProfileScreen._gold)
                : Image.asset(option.asset, fit: BoxFit.contain),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tributeHistoryLabel(keepsake.item, characterName),
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: CharacterProfileScreen._ink,
                  ),
                ),
                if (when.isNotEmpty)
                  Text(
                    when,
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: CharacterProfileScreen._muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
