import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'character_profiles.dart';

/// Characters and gifts the worker added or changed since this build was
/// made — GET /api/catalogue, written in backend/src/catalogue.js.
///
/// The app still ships a complete roster and gift list. This is a DELTA laid
/// over them: entries with an id the build does not know are added, entries
/// with a known id replace the fields they carry, and the hidden lists take
/// things off screen. So a build with no network, or a worker with an empty
/// catalogue, shows exactly what it was built with — which is also why
/// nothing here can fail loudly. A malformed entry is dropped on its own and
/// a malformed response is ignored whole.
///
/// Three moments:
///  - [loadCached] before the first frame, from SharedPreferences, so a
///    character added last week is on the dashboard at first paint;
///  - [refresh] right after, and again when the app is resumed, from the
///    worker; a change bumps [revision], which the dashboard listens to;
///  - everything else reads [current] synchronously, through the same
///    names the code used when the lists were constants (`kCharacters`,
///    `kTributeOptions`, `profileForCharacter`).
class RemoteCatalogue {
  /// Character entries, normalised: 'color' is a [Color], 'image' is whatever
  /// [catalogueImageProvider] can draw. A new character has every roster
  /// field; an override has 'id' and only what changed.
  final List<Map<String, dynamic>> characters;
  final Set<String> hiddenCharacters;

  /// Group name ('greek' | 'modern') to the ids in it, when the worker
  /// re-sorted that group.
  final Map<String, List<String>> order;
  final Map<String, CharacterProfile> profiles;

  /// Gift entries as the worker sent them, keyed by 'item'. Turned into
  /// TributeOptions in coins_sheet.dart, where that class lives.
  final List<Map<String, dynamic>> gifts;
  final Set<String> hiddenGifts;

  /// Notification lines by character id.
  final Map<String, List<String>> nudges;

  /// Switches the worker sets (`features` in backend/src/catalogue.js). Read
  /// with [feature]; one that is absent is off.
  final Map<String, bool> features;

  /// The build number of what the worker is serving, for the version line
  /// in Settings. Null when it has not been heard (never fetched, or a
  /// worker older than this field).
  final String? serverBuild;

  const RemoteCatalogue({
    this.characters = const [],
    this.hiddenCharacters = const {},
    this.order = const {},
    this.profiles = const {},
    this.gifts = const [],
    this.hiddenGifts = const {},
    this.nudges = const {},
    this.features = const {},
    this.serverBuild,
  });

  /// Whether the worker has switched [name] on. Off when the catalogue has
  /// never been fetched, so a feature the worker gates stays shut on a first
  /// launch with no network rather than guessing.
  bool feature(String name) => features[name] == true;

  static const RemoteCatalogue empty = RemoteCatalogue();

  /// What every reader sees. Replaced whole, never mutated, so a list handed
  /// out a moment ago stays internally consistent.
  static RemoteCatalogue current = empty;

  /// Bumped whenever [current] changes. Listen to rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// The asset paths compiled into this build, once [loadCached] has read the
  /// manifest. Null before that (and in unit tests), which is treated as
  /// "nothing is bundled": a catalogue image is then fetched, never assumed.
  static Set<String>? bundledAssets;

  /// Completes when the first [refresh] of this launch has finished, however
  /// it ended. A deep link to a character this build has never heard of
  /// waits on it before deciding the character does not exist.
  static Future<void> get firstRefresh => _firstRefresh.future;
  static Completer<void> _firstRefresh = Completer<void>();

  static const String _kCacheKey = 'remote_catalogue_v1';
  static const Duration _minRefreshGap = Duration(minutes: 10);
  static DateTime? _lastRefresh;
  static Future<void>? _inFlight;

  /// The schema this build understands. A response with a higher number is
  /// ignored rather than half-read — see CATALOGUE_SCHEMA in catalogue.js.
  static const int supportedSchema = 1;

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  /// Reads the asset manifest and the last catalogue this install fetched.
  /// Fast and local; awaited before runApp.
  static Future<void> loadCached() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      bundledAssets = manifest.listAssets().toSet();
    } catch (_) {
      bundledAssets = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCacheKey);
      if (raw == null || raw.isEmpty) return;
      final parsed = tryParse(jsonDecode(raw));
      if (parsed != null) _install(parsed);
    } catch (e) {
      if (kDebugMode) debugPrint('Catalogue cache unreadable: $e');
    }
  }

  /// Asks the worker. Never throws; a failure leaves [current] as it was.
  /// Calls closer together than ten minutes are skipped unless [force], so
  /// flicking between apps does not turn into a request each time.
  static Future<void> refresh({bool force = false, Dio? dio}) {
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastRefresh;
    if (!force && last != null && DateTime.now().difference(last) < _minRefreshGap) {
      return Future<void>.value();
    }
    final future = _refresh(dio ?? Dio()).whenComplete(() {
      _inFlight = null;
      if (!_firstRefresh.isCompleted) _firstRefresh.complete();
    });
    _inFlight = future;
    return future;
  }

  static Future<void> _refresh(Dio dio) async {
    final url = AppConfig.apiUrl('/api/catalogue');
    if (url.isEmpty) return;
    try {
      final res = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (status) => status == 200,
        ),
      );
      final raw = res.data;
      if (raw == null || raw.isEmpty) return;
      final parsed = tryParse(jsonDecode(raw));
      if (parsed == null) return;
      _lastRefresh = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      final changed = prefs.getString(_kCacheKey) != raw;
      if (changed) await prefs.setString(_kCacheKey, raw);
      // Installed even when the bytes match the cache: the cache may have
      // been written by a launch whose manifest read differed.
      if (changed || identical(current, empty)) _install(parsed);
    } catch (e) {
      if (kDebugMode) debugPrint('Catalogue refresh failed: $e');
    }
  }

  static void _install(RemoteCatalogue next) {
    current = next;
    revision.value++;
  }

  /// For tests: put a catalogue in place, or pass null to go back to none.
  @visibleForTesting
  static void debugSet(RemoteCatalogue? catalogue) {
    _install(catalogue ?? empty);
  }

  /// For tests: forget that a refresh ever ran.
  @visibleForTesting
  static void debugReset() {
    current = empty;
    bundledAssets = null;
    _lastRefresh = null;
    _inFlight = null;
    _firstRefresh = Completer<void>();
  }

  // ---------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------

  static final RegExp _idPattern = RegExp(r'^[a-z0-9_]{1,40}$');
  static final RegExp _itemPattern = RegExp(r'^[a-z_]{1,40}$');
  static final RegExp _colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// The catalogue in [json], or null when it is not one this build can
  /// read. Individual bad entries are skipped, not fatal.
  static RemoteCatalogue? tryParse(dynamic json) {
    if (json is! Map) return null;
    final schema = json['schema'];
    if (schema is! int || schema < 1 || schema > supportedSchema) return null;

    final characters = <Map<String, dynamic>>[];
    final profiles = <String, CharacterProfile>{};
    final nudges = <String, List<String>>{};

    for (final entry in _maps(json['characters'])) {
      final id = entry['id'];
      if (id is! String || !_idPattern.hasMatch(id)) continue;
      final out = <String, dynamic>{'id': id};
      for (final field in const ['name', 'vibe', 'desc', 'tagline', 'group']) {
        final value = _text(entry[field]);
        if (value != null) out[field] = value;
      }
      final image = _resolveImage(entry['image'], entry['image_url']);
      if (image != null) out['image'] = image;
      final color = entry['color'];
      if (color is String && _colorPattern.hasMatch(color)) {
        out['color'] = Color(0xFF000000 | int.parse(color.substring(1), radix: 16));
      }
      characters.add(out);

      final profile = _profile(entry['profile']);
      if (profile != null) profiles[id] = profile;
      final lines = _textList(entry['nudges']);
      if (lines.isNotEmpty) nudges[id] = lines;
    }

    // The top-level map is for characters the build already has; where both
    // name a character, the top-level one wins, being the later edit.
    final overrides = json['nudges'];
    if (overrides is Map) {
      overrides.forEach((key, value) {
        final lines = _textList(value);
        if (key is String && _idPattern.hasMatch(key) && lines.isNotEmpty) {
          nudges[key] = lines;
        }
      });
    }

    final order = <String, List<String>>{};
    final rawOrder = json['order'];
    if (rawOrder is Map) {
      rawOrder.forEach((key, value) {
        final ids = _textList(value).where(_idPattern.hasMatch).toList();
        if (key is String && ids.isNotEmpty) order[key] = ids;
      });
    }

    final gifts = <Map<String, dynamic>>[];
    for (final entry in _maps(json['gifts'])) {
      final item = entry['item'];
      if (item is! String || !_itemPattern.hasMatch(item)) continue;
      final out = <String, dynamic>{'item': item};
      for (final field in const ['label', 'detail', 'giving', 'heldBadge', 'heldDetail']) {
        final value = _text(entry[field]);
        if (value != null) out[field] = value;
      }
      final image = _resolveImage(entry['image'], entry['image_url']);
      if (image != null) out['image'] = image;
      if (entry['once'] is bool) out['once'] = entry['once'];
      final price = entry['price'];
      if (price is int && price > 0) out['price'] = price;
      gifts.add(out);
    }

    final features = <String, bool>{};
    final rawFeatures = json['features'];
    if (rawFeatures is Map) {
      rawFeatures.forEach((key, value) {
        if (key is String && value is bool) features[key] = value;
      });
    }

    final rawBuild = json['server_build'];
    final serverBuild = rawBuild is String && RegExp(r'^\d{1,9}$').hasMatch(rawBuild)
        ? rawBuild
        : null;

    return RemoteCatalogue(
      serverBuild: serverBuild,
      features: Map.unmodifiable(features),
      characters: List.unmodifiable(characters),
      hiddenCharacters: _textList(json['hidden_characters']).toSet(),
      order: Map.unmodifiable(order),
      profiles: Map.unmodifiable(profiles),
      gifts: List.unmodifiable(gifts),
      hiddenGifts: _textList(json['hidden_gifts']).toSet(),
      nudges: Map.unmodifiable(nudges),
    );
  }

  static Iterable<Map<String, dynamic>> _maps(dynamic value) sync* {
    if (value is! List) return;
    for (final entry in value) {
      if (entry is Map) yield Map<String, dynamic>.from(entry);
    }
  }

  static String? _text(dynamic value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static List<String> _textList(dynamic value) => value is List
      ? [for (final v in value) if (_text(v) != null) v as String]
      : const <String>[];

  static CharacterProfile? _profile(dynamic value) {
    if (value is! Map) return null;
    final age = _text(value['age']);
    final about = _text(value['about']);
    final verse = _text(value['verse']);
    final tags = _textList(value['tags']);
    final asks = _textList(value['asks']);
    if (age == null || about == null || verse == null || tags.isEmpty || asks.isEmpty) {
      return null;
    }
    return CharacterProfile(age: age, tags: tags, about: about, asks: asks, verse: verse);
  }

  /// An image this build can draw: the asset path when the file is compiled
  /// in, otherwise the URL the worker publishes it at.
  static String? _resolveImage(dynamic image, dynamic imageUrl) {
    final path = _text(image);
    final url = _text(imageUrl);
    if (path != null && path.startsWith('https://')) return path;
    if (path != null && (bundledAssets?.contains(path) ?? false)) return path;
    if (url != null && url.startsWith('https://')) return url;
    // No URL to fall back on: hand back the path and let the image's error
    // handler deal with a file that is not there.
    return path;
  }

  // ---------------------------------------------------------------------
  // Merging the roster
  // ---------------------------------------------------------------------

  static const List<String> _rosterFields = ['name', 'vibe', 'desc', 'image', 'color'];

  // One merged roster is kept, for the catalogue and bundled list it was
  // made from. Static because the class is const-constructible; keyed by
  // identity because a new catalogue is a new object.
  static RemoteCatalogue? _mergedFor;
  static List<Map<String, dynamic>>? _mergedFrom;
  static List<Map<String, dynamic>>? _mergedCharacters;

  /// [bundled] with this catalogue laid over it: overrides applied in place,
  /// new characters appended. Hidden characters are still in the list — a
  /// chat with one must keep resolving — and are left out by [groupIds].
  List<Map<String, dynamic>> mergeCharacters(List<Map<String, dynamic>> bundled) {
    if (characters.isEmpty) return bundled;
    final cached = _mergedCharacters;
    if (cached != null &&
        identical(_mergedFor, this) &&
        identical(_mergedFrom, bundled)) {
      return cached;
    }

    final byId = {for (final c in characters) c['id'] as String: c};
    final known = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final character in bundled) {
      final id = character['id'] as String;
      known.add(id);
      final override = byId[id];
      merged.add(override == null ? character : {...character, ...override});
    }
    for (final character in characters) {
      if (known.contains(character['id'])) continue;
      // A new character missing a field every card reads would be a crash or
      // a blank tile; leave it out until the worker sends it whole.
      if (_rosterFields.any((f) => character[f] == null)) continue;
      merged.add(character);
    }
    _mergedFor = this;
    _mergedFrom = bundled;
    return _mergedCharacters = List.unmodifiable(merged);
  }

  /// The ids in dashboard group [group], in display order.
  ///
  /// [bundledIds] is the build's own list for that group; a character the
  /// worker moved to another group leaves it. [roster] is the merged roster:
  /// an id with no entry there is dropped.
  List<String> groupIds(
    String group,
    List<String> bundledIds,
    List<Map<String, dynamic>> roster,
  ) {
    final exists = {for (final c in roster) c['id'] as String};
    final movedAway = {
      for (final c in characters)
        if (c['group'] != null && c['group'] != group) c['id'] as String,
    };
    final ids = <String>[];
    void add(String id) {
      if (!exists.contains(id) || hiddenCharacters.contains(id)) return;
      if (!ids.contains(id)) ids.add(id);
    }

    final reordered = order[group];
    if (reordered != null) {
      for (final id in reordered) {
        add(id);
      }
    }
    for (final id in bundledIds) {
      if (!movedAway.contains(id)) add(id);
    }
    for (final c in characters) {
      if (c['group'] == group) add(c['id'] as String);
    }
    return ids;
  }
}

/// The version line in Settings: "1.0.6 build 99 · server build 100".
///
/// One version number, on purpose. The app's version and build are its own;
/// of the server only the build is shown, because "1.0.6" beside "1.0.7"
/// reads as something being wrong when it is only the server having moved
/// on, which it is meant to do. With no server build to show (offline, never
/// fetched) the line is the app's alone.
String versionLine({
  required String version,
  required String buildNumber,
  String? serverBuild,
}) {
  final app = '$version build $buildNumber';
  return serverBuild == null ? app : '$app · server build $serverBuild';
}

/// Draws a roster or gift image wherever it lives: compiled into the build
/// (an asset path) or published by the worker (an https URL), which is where
/// the art for anything added after this build comes from.
ImageProvider catalogueImageProvider(String path) {
  if (path.startsWith('https://') || path.startsWith('http://')) {
    return NetworkImage(path);
  }
  return AssetImage(path);
}

/// [Image] over [catalogueImageProvider], with a quiet placeholder instead of
/// a red error box when a remote file cannot be fetched (offline on the first
/// launch after a character was added).
class CatalogueImage extends StatelessWidget {
  final String path;
  final BoxFit? fit;
  final double? width;
  final double? height;

  const CatalogueImage(this.path, {super.key, this.fit, this.width, this.height});

  @override
  Widget build(BuildContext context) {
    return Image(
      image: catalogueImageProvider(path),
      fit: fit,
      width: width,
      height: height,
      errorBuilder: (context, error, stack) => SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(color: Color(0x14000000)),
      ),
    );
  }
}
