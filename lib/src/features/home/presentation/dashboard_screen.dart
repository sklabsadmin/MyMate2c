import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/data/character_profiles.dart';
import '../../../core/data/characters.dart';
import '../../character/presentation/character_profile_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// The shared roster (lib/core/data/characters.dart). Kept as a getter so
  /// the rest of this file is unchanged.
  List<Map<String, dynamic>> get _characters => kCharacters;

  /// Built-in characters allowed by AppConfig.visibleCharacterIds, in that
  /// list's order.
  List<Map<String, dynamic>> get _visibleCharacters {
    return AppConfig.visibleCharacterIds
        .map((id) => _characters.firstWhere((c) => c['id'] == id))
        .toList();
  }

  /// Characters for one dashboard group, in the group list's order. Ids with
  /// no matching entry are skipped rather than throwing, so a typo in
  /// AppConfig hides one card instead of taking down the whole dashboard.
  List<Map<String, dynamic>> _charactersForGroup(List<String> ids) {
    return ids
        .map((id) => _characters.where((c) => c['id'] == id).firstOrNull)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// The linked Google account's own avatar, shown top-right once signed in.
  ///
  /// Renders nothing at all when signed out, on Instagram sessions, or when
  /// Google returned no picture — an empty SizedBox rather than a placeholder,
  /// so the header looks unchanged for users who have never linked.
  Widget _googleAvatar(ThemeData theme) {
    final auth = ref.watch(authProvider).value;
    final url = auth?.avatarUrl;
    if (auth == null || !auth.authenticated || url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: GestureDetector(
        onTap: () => context.push('/settings'),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: theme.primaryColor.withOpacity(0.6),
              width: 2,
            ),
          ),
          child: ClipOval(
            child: Image.network(
              url,
              fit: BoxFit.cover,
              // Google avatar URLs can 403 once the reference ages out, so
              // never let a broken image take the header down with it.
              errorBuilder: (_, _, _) => Container(
                color: Colors.white.withOpacity(0.1),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.person,
                  size: 18,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Greeting driven by the viewer's own device clock — DateTime.now() is
  /// local time, so this follows whatever timezone they are actually in.
  ///
  ///   05:00 – 11:59  Good Morning
  ///   12:00 – 16:59  Good Afternoon
  ///   17:00 – 21:59  Good Evening
  ///   22:00 – 04:59  Still awake?
  ///
  /// Each is prefixed with "Welcome, " by the caller, so the bands are
  /// written to read naturally after it — including the late one, where
  /// "Welcome, Still awake?" still scans.
  ///
  /// The late band exists because the naive version greeted someone at 2am
  /// with "Good Morning" — technically true, but it reads as a bug. "Still
  /// awake" suits the hour and the app's tone better than a fourth
  /// "Good ..." variant.
  String _timeOfDayGreeting() {
    final hour = DateTime.now().hour;
    if (hour >= 22 || hour < 5) return 'Still awake?';
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  /// One per tab, so a mouse wheel anywhere on the page can drive whichever
  /// grid is currently showing. Three covers the optional custom tab; the
  /// spare is simply never attached.
  final List<ScrollController> _gridControllers = List.generate(
    3,
    (_) => ScrollController(),
  );

  /// Which tab the wheel should scroll. Kept in sync from the TabController
  /// below rather than read on demand, because the pointer handler sits above
  /// the DefaultTabController and cannot look it up.
  int _activeTab = 0;

  /// The TabController we have already subscribed to, so rebuilds do not stack
  /// up duplicate listeners.
  TabController? _syncedTabs;

  @override
  void initState() {
    super.initState();
    // Precache all character images for smooth scrolling
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final character in _visibleCharacters) {
        precacheImage(AssetImage(character['image'] as String), context);
      }
    });
  }

  @override
  void dispose() {
    for (final c in _gridControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// Sends a mouse-wheel notch to the visible grid regardless of what the
  /// pointer happens to be over.
  ///
  /// Flutter routes wheel events by pointer position, so the wheel did
  /// nothing unless the cursor was over the grid itself — over the greeting,
  /// the heading, the tab bar, or the empty surround beside the capped column,
  /// the page simply refused to move. On a desktop mouse that reads as broken.
  ///
  /// Ignores the event when the grid is short enough not to scroll (no
  /// clients, or nothing to scroll to), so it never fights a non-scrolling
  /// tab.
  void _handleWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final controller = _gridControllers[_activeTab];
    if (!controller.hasClients) return;
    final position = controller.position;
    if (position.maxScrollExtent <= 0) return;
    controller.jumpTo(
      (position.pixels + event.scrollDelta.dy).clamp(
        0.0,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final customChars = AppConfig.enableCustomCharacters
        ? ref.watch(customCharactersProvider)
        : const <Map<String, dynamic>>[];

    final theme = Theme.of(context);
    final score = ref.watch(userScoreProvider);
    final level = 1 + (score ~/ 10);

    return Scaffold(
      // Wraps the entire page, not just the grid, so the wheel works over the
      // greeting, the heading, the tab bar and the surround beside the capped
      // column — see _handleWheel.
      body: Listener(
        onPointerSignal: _handleWheel,
        child: Stack(
          children: [
            // Background
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.scaffoldBackgroundColor,
                    Colors.black,
                    theme.primaryColor.withOpacity(0.1),
                  ],
                ),
              ),
            ),

            SafeArea(
              child: Padding(
                // No bottom padding: the character grid runs to the edge of
                // the body so its clipped last row meets the nav bar directly.
                // Padding there left a band of background between the fade and
                // the bar, which read as the grid floating short of the bottom.
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Welcome, ${_timeOfDayGreeting()}',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                        // Relationship Level Indicator AND Settings
                        Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.favorite,
                                      size: 14,
                                      color: theme.primaryColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Level $level',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                // Progress Bar
                                Container(
                                  width: 80,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor:
                                        (score % 10) /
                                        10.0, // Mock progress for level
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: theme.primaryColor,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            // Google account avatar, once linked. Sits before
                            // the settings gear so the gear stays the
                            // rightmost control it has always been.
                            _googleAvatar(theme),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: () => context.push('/settings'),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.2),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.settings,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),

                    Text(
                      // "Personality", not "character", to match the nav
                      // label this tab is reached by.
                      'Choose a Personality to Explore',
                      // Deliberately a step down from headlineSmall:
                      // the ask was for this line to sit a little
                      // smaller than a full heading.
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // One tab per character group, Greek first. Custom
                    // characters get their own trailing tab so they never
                    // mix into the built-in groups.
                    Expanded(
                      child: DefaultTabController(
                        length: AppConfig.enableCustomCharacters ? 3 : 2,
                        // Keeps _activeTab in step so the wheel drives whichever
                        // grid is on screen. Covers swipes as well as taps,
                        // which onTap alone would miss.
                        child: Builder(
                          builder: (context) {
                            final tabs = DefaultTabController.of(context);
                            if (_syncedTabs != tabs) {
                              _syncedTabs = tabs;
                              tabs.addListener(() {
                                if (!mounted) return;
                                if (tabs.index != _activeTab) {
                                  setState(() => _activeTab = tabs.index);
                                }
                              });
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Styled as a filled segmented control rather than
                                // underlined text: on first open the Greek tab is
                                // selected, and the unselected segments need to
                                // read clearly as "there is more here", not as
                                // decoration above the grid.
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.07),
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.12),
                                    ),
                                  ),
                                  child: TabBar(
                                    labelColor: Colors.white,
                                    unselectedLabelColor: Colors.white70,
                                    dividerColor: Colors.transparent,
                                    indicatorSize: TabBarIndicatorSize.tab,
                                    splashBorderRadius: BorderRadius.circular(
                                      18,
                                    ),
                                    indicator: BoxDecoration(
                                      color: theme.primaryColor,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    labelPadding: EdgeInsets.zero,
                                    labelStyle: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.1,
                                    ),
                                    unselectedLabelStyle: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1.1,
                                    ),
                                    tabs: [
                                      _buildTab(AppConfig.greekSectionTitle),
                                      _buildTab(AppConfig.modernSectionTitle),
                                      if (AppConfig.enableCustomCharacters)
                                        _buildTab('Yours'),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: TabBarView(
                                    children: [
                                      _buildCharacterGrid(
                                        _charactersForGroup(
                                          AppConfig.greekCharacterIds,
                                        ),
                                        theme,
                                        controller: _gridControllers[0],
                                      ),
                                      _buildCharacterGrid(
                                        _charactersForGroup(
                                          AppConfig.modernCharacterIds,
                                        ),
                                        theme,
                                        controller: _gridControllers[1],
                                      ),
                                      if (AppConfig.enableCustomCharacters)
                                        _buildCharacterGrid(
                                          customChars,
                                          theme,
                                          trailingCreateCard: true,
                                          controller: _gridControllers[2],
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A tab label, uppercased for display. In mixed case at this size the
  /// "rn" in "Modern" runs together and reads as "Modem"; caps plus letter
  /// spacing removes the ambiguity, which is what lets the label sit at
  /// 12pt. The config values stay in normal case so they read naturally in
  /// code.
  Widget _buildTab(String title) {
    return Tab(height: 22, child: Text(title.toUpperCase()));
  }

  /// The card grid for one tab. Empty groups show a short placeholder
  /// rather than a blank pane, so an empty tab still reads as intentional.
  Widget _buildCharacterGrid(
    List<Map<String, dynamic>> characters,
    ThemeData theme, {
    bool trailingCreateCard = false,
    ScrollController? controller,
  }) {
    if (characters.isEmpty && !trailingCreateCard) {
      return Center(
        child: Text(
          'Nobody here yet.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white38),
        ),
      );
    }

    final itemCount = characters.length + (trailingCreateCard ? 1 : 0);

    // Always two across, on every viewport width, and sized to show exactly
    // one 2x2 screenful. When a group holds more than four, the grid is made
    // slightly taller so the next row peeks in underneath — that sliver of
    // artwork is what tells people to keep scrolling. The width cap stops
    // two columns from stretching into full-screen cards on desktop.
    // Align rather than Center: the grid is pinned to the top of whatever
    // space it is given, so any shortfall shows up as one gap at the bottom
    // that the fill logic below can close, not as two half-gaps.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 16.0;

            // Half a card of the next row stays in view, which together with
            // the two full rows above it is the 2.5 rows the grid is sized
            // for. Must match minRowsVisible below — a smaller peek would
            // size cards for 2.5 rows but only ever reveal 2.2 of them.
            const peekFraction = 0.5;

            // At least two and a half rows should be in view, so the grid
            // never reads as a single row of cards with space beneath. On a
            // short window that means shorter cards rather than fewer rows:
            // the height is derived from the space available, not fixed.
            const minRowsVisible = 2.5;

            // Card proportions stay between these bounds so the adaptive
            // height can't produce something absurd — 0.75 is the original
            // portrait shape and the tallest allowed; 0.6 lets cards go
            // wide-ish on a short window, which is what buys the 2.5 rows
            // there. A tighter floor left cards too tall to fit 2.5 and the
            // grid quietly fell back to two.
            const tallestRatio = 0.75;
            const squattestRatio = 0.6;

            final available = constraints.maxHeight;
            final cardWidth = (constraints.maxWidth - spacing) / 2;

            final fitHeight = (available - (2 * spacing)) / minRowsVisible;
            final cardHeight = fitHeight.clamp(
              cardWidth * squattestRatio,
              cardWidth / tallestRatio,
            );
            final aspectRatio = cardWidth / cardHeight;
            final rowStride = cardHeight + spacing;

            final totalRows = (itemCount / 2).ceil();
            final contentHeight =
                (totalRows * cardHeight) + ((totalRows - 1) * spacing);

            // When the group overflows, the grid fills the whole space it has
            // been given rather than stopping at a computed row boundary.
            //
            // Two reasons. Cards are already sized so ~2.5 rows fit, so
            // filling lands the cut mid-card without extra arithmetic. And
            // leaving dead space below meant the fade ended in mid-air with
            // its own bottom edge showing against the purple backdrop — a
            // floating band. Reaching the bottom puts that edge flush against
            // the nav bar, where there is nothing to see it against.
            //
            // When the whole group already fits, none of this applies: the
            // grid takes its natural height and nothing is clipped, because
            // faking a cut-off row when there is nothing below reads as a
            // rendering bug rather than an invitation.
            final double height;
            final bool scrollable;
            if (contentHeight <= available) {
              height = contentHeight;
              scrollable = false;
            } else {
              height = available;
              scrollable = true;
            }

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    GridView.builder(
                      controller: controller,
                      padding: EdgeInsets.zero,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: aspectRatio,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                      ),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        if (index == characters.length) {
                          return _buildCreateNewCard(theme, compact: false);
                        }
                        return _buildCharacterCard(
                          characters[index],
                          theme,
                          compact: false,
                        );
                      },
                    ),
                    // Softens the clipped row into a fade rather than a hard
                    // cut.
                    //
                    // Fades to black rather than to scaffoldBackgroundColor:
                    // the page behind sits on a purple gradient, so a solid
                    // scaffold colour ended in a hue that did not match its
                    // surroundings and the gradient's own bottom edge became
                    // visible as a floating band. Black shares the backdrop's
                    // darkest tone, so the ramp reads as the artwork dimming
                    // out instead of a rectangle laid over it.
                    //
                    // IgnorePointer so it never swallows a scroll or a tap on
                    // the card underneath.
                    if (scrollable)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: cardHeight * peekFraction,
                        child: IgnorePointer(
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: [0.0, 0.45, 1.0],
                                colors: [
                                  Color(0x00000000),
                                  Color(0x33000000),
                                  Color(0xF2000000),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Opens a character's profile from the dashboard.
  ///
  /// Backing out returns here, to the character list — the profile was opened
  /// from the dashboard, so that is where "back" belongs. Chat is only opened
  /// when the user actually taps an "Ask Me About" opener, which arrives as
  /// the pop result and is then sent as the first message.
  Future<void> _openProfileFor(Map<String, dynamic> character) async {
    final profile = profileForCharacter(character['id'] as String?);
    if (profile == null) return;

    final question = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CharacterProfileScreen(
          name: character['name'] as String,
          title: character['vibe'] as String,
          imagePath: character['image'] as String,
          profile: profile,
          // Messages are keyed by the scenario string the chat screen uses.
          chatId: '${character['name']} (${character['vibe']})',
          characterKey: character['id'] as String?,
        ),
      ),
    );

    // Null means the user backed out rather than picking an opener — stay on
    // the dashboard instead of pushing them into a chat they didn't ask for.
    if (!mounted || question == null || question.isEmpty) return;
    _openChat(character, initialMessage: question);
  }

  void _openChat(Map<String, dynamic> character, {String? initialMessage}) {
    final characterId = character['id'] as String?;
    final openerParam = (initialMessage != null && initialMessage.isNotEmpty)
        ? 'initialMessage=${Uri.encodeComponent(initialMessage)}'
        : '';

    // Built-in characters go through the short /c/<id> route. It carries the
    // same information, but the address bar then reflects the conversation:
    // a reload keeps you in it instead of dropping you back here, and the URL
    // can be copied to someone else.
    //
    // go(), not push(): the chat lives in a different branch of the nav-bar
    // shell, and pushing across branches leaves the shell's location — and so
    // the URL — on the branch you started from. That is why opening a chat
    // used to leave the address bar showing /dashboard. The chat's back arrow
    // already falls back to go('/dashboard') when there is nothing to pop.
    if (characterId != null && characterById(characterId) != null) {
      context.go(
        '/c/$characterId${openerParam.isEmpty ? '' : '?$openerParam'}',
      );
      return;
    }

    // User-created characters aren't in the shared roster, so nothing could
    // resolve /c/<id> for them — they keep the long self-describing form.
    final characterIdParam = (characterId != null && characterId.isNotEmpty)
        ? '&characterId=${Uri.encodeComponent(characterId)}'
        : '';
    context.push(
      '/chat/session?scenario=${Uri.encodeComponent('${character['name']} (${character['vibe']})')}'
      '&characterImage=${Uri.encodeComponent(character['image'])}'
      '&isRoleplay=false$characterIdParam'
      '${openerParam.isEmpty ? '' : '&$openerParam'}',
    );
  }

  Widget _buildCharacterCard(
    Map<String, dynamic> character,
    ThemeData theme, {
    required bool compact,
  }) {
    final isCustom = character['isCustom'] == true;
    final hasProfile = profileForCharacter(character['id'] as String?) != null;

    return _HoverRegion(
      builder: (hovering) => Stack(
        children: [
          _buildCardBody(
            character,
            theme,
            compact: compact,
            isCustom: isCustom,
            hovering: hovering,
          ),
          // Profile affordance. Always rendered when a profile exists — not
          // hover-only — because touch devices have no hover state and would
          // otherwise never see it. Pointer devices get a stronger version
          // on hover; touch users get a permanently tappable target.
          if (hasProfile)
            Positioned(
              top: compact ? 6 : 10,
              right: compact ? 6 : 10,
              child: _ProfileBadge(
                highlighted: hovering,
                onTap: () => _openProfileFor(character),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCardBody(
    Map<String, dynamic> character,
    ThemeData theme, {
    required bool compact,
    required bool isCustom,
    bool hovering = false,
  }) {
    // Each character's own accent colour, so the glow reads as *that*
    // character lighting up rather than a generic UI highlight.
    final accent = (character['color'] as Color?) ?? theme.primaryColor;
    return GestureDetector(
      onTap: () => _openChat(character),
      onLongPress: isCustom
          ? () {
              // Show delete dialog for custom characters
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete Custom Character?'),
                  content: Text(
                    'Are you sure you want to delete ${character['name']}?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await ref
                            .read(customCharactersProvider.notifier)
                            .deleteCharacter(character['id']);
                        // No need to setState, provider will update UI
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(compact ? 14 : 20),
          border: Border.all(
            color: hovering
                ? accent.withValues(alpha: 0.95)
                : theme.primaryColor.withOpacity(0.3),
            width: hovering ? 2 : 1,
          ),
          boxShadow: hovering
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.55),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ]
              : null,
          image: DecorationImage(
            image: AssetImage(character['image']),
            fit: BoxFit.cover,
            // Removed opacity to make image clear
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 14 : 20),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.5, 1.0], // Gradient starts halfway down
              colors: [Colors.transparent, Colors.black.withOpacity(0.9)],
            ),
          ),
          padding: EdgeInsets.all(compact ? 6 : 12),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      character['name'],
                      style: compact
                          ? theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            )
                          : theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      character['vibe'],
                      style:
                          (compact
                                  ? theme.textTheme.bodySmall
                                  : theme.textTheme.bodyMedium)
                              ?.copyWith(
                                color: theme.colorScheme.secondary,
                                fontWeight: FontWeight.bold,
                              ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        character['desc'],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isCustom)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 6 : 8,
                      vertical: compact ? 2 : 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.pink.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(compact ? 10 : 12),
                    ),
                    child: Text(
                      'CUSTOM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 8 : 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCreateNewCard(ThemeData theme, {required bool compact}) {
    final isPremium = ref.read(userSubscriptionProvider);

    return GestureDetector(
      onTap: () {
        if (!isPremium) {
          context.push('/paywall');
          return;
        }
        context.push('/create-character');
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(compact ? 14 : 20),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            style: BorderStyle.solid,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 8 : 16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor.withOpacity(0.2),
                    ),
                    child: Icon(
                      Icons.add,
                      color: theme.primaryColor,
                      size: compact ? 20 : 32,
                    ),
                  ),
                  SizedBox(height: compact ? 6 : 12),
                  Text(
                    'Create Custom',
                    style: compact
                        ? theme.textTheme.bodySmall
                        : theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            if (!isPremium)
              Positioned(
                top: compact ? 6 : 12,
                right: compact ? 6 : 12,
                child: Container(
                  padding: EdgeInsets.all(compact ? 4 : 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.lock,
                    color: Colors.amber,
                    size: compact ? 12 : 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tracks pointer hover so a child can render a stronger affordance on
/// desktop. On touch devices onEnter/onExit never fire, so `hovering` stays
/// false and the child must still be usable in that state.
class _HoverRegion extends StatefulWidget {
  final Widget Function(bool hovering) builder;

  const _HoverRegion({required this.builder});

  @override
  State<_HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<_HoverRegion> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: widget.builder(_hovering),
    );
  }
}

/// The "open profile" affordance on a character card.
///
/// Visible at all times so touch users have something to tap, but quiet
/// enough not to compete with the artwork: a small translucent dot. On hover
/// it brightens and grows a "Profile" label, which is the desktop cue that
/// the card holds more than a chat.
class _ProfileBadge extends StatelessWidget {
  final bool highlighted;
  final VoidCallback onTap;

  const _ProfileBadge({required this.highlighted, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: highlighted ? 10 : 6,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: highlighted
                ? theme.primaryColor.withOpacity(0.95)
                : Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(highlighted ? 0.9 : 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 14, color: Colors.white),
              // The label only appears on hover; on a phone the icon alone
              // has to carry it, which is why the dot is always present.
              if (highlighted) ...[
                const SizedBox(width: 4),
                const Text(
                  'Profile',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
