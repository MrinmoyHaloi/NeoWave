import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../components/inputs.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// One jump target in Settings search.
///
/// [id] is the `id` of the `_Group` it scrolls to; [section] is the rail
/// section that group lives in. [keywords] lists the individual settings
/// inside the group, so a search for "crossfade" finds the Playback card.
class SettingsSearchEntry {
  final String id;
  final String section;
  final String title;
  final String subtitle;
  final String keywords;
  const SettingsSearchEntry({
    required this.id,
    required this.section,
    required this.title,
    this.subtitle = '',
    this.keywords = '',
  });
}

/// Every searchable settings card. Keep ids in step with the `id:` passed
/// to `_Group` in `settings_page.dart`.
const settingsSearchEntries = <SettingsSearchEntry>[
  SettingsSearchEntry(
    id: 'general.behaviour',
    section: 'general',
    title: 'Behaviour',
    subtitle: 'Startup and window defaults',
    keywords: 'close button minimize tray background window startup',
  ),
  SettingsSearchEntry(
    id: 'general.backup',
    section: 'general',
    title: 'Backup',
    subtitle: 'Move your playlists and settings to another device',
    keywords: 'export import json restore backup playlists migrate',
  ),
  SettingsSearchEntry(
    id: 'general.cache',
    section: 'general',
    title: 'Cached data',
    subtitle: 'Pages saved on this device so they open instantly',
    keywords: 'cache clear storage snapshot disk space lyrics home offline',
  ),
  SettingsSearchEntry(
    id: 'general.diagnostics',
    section: 'general',
    title: 'Diagnostics',
    subtitle: 'Local logs for troubleshooting',
    keywords: 'logs verbose logging export log folder crash report debug',
  ),
  SettingsSearchEntry(
    id: 'playback.main',
    section: 'playback',
    title: 'Playback',
    subtitle: 'Gapless, crossfade and output behaviour',
    keywords: 'autoplay similar crossfade gapless radio queue ends',
  ),
  SettingsSearchEntry(
    id: 'audio.output',
    section: 'audio',
    title: 'Audio output',
    subtitle: 'Choose the output device',
    keywords: 'device output speakers headphones audio',
  ),
  SettingsSearchEntry(
    id: 'audio.quality',
    section: 'audio',
    title: 'Streaming and Download quality',
    subtitle: 'YouTube Music streams: Opus or AAC',
    keywords: 'opus aac quality streaming download bitrate data saver',
  ),
  SettingsSearchEntry(
    id: 'audio.loudness',
    section: 'audio',
    title: 'Loudness',
    subtitle: 'Track or album normalization',
    keywords: 'loudness replaygain normalization volume',
  ),
  SettingsSearchEntry(
    id: 'library.downloads',
    section: 'library',
    title: 'Offline',
    subtitle: 'Download behaviour, save location and folder layout',
    keywords: 'download lyrics lrc save location folder layout artist album '
        'year reorganize directory',
  ),
  SettingsSearchEntry(
    id: 'library.sync',
    section: 'library',
    title: 'Library',
    subtitle: 'YouTube Music sync and hidden tracks',
    keywords: 'sync youtube music playlists liked songs two-way'
        'hidden exclusions restore sync now',
  ),
  SettingsSearchEntry(
    id: 'lyrics.timing',
    section: 'lyrics',
    title: 'Timing',
    subtitle: 'Synced lyrics providers',
    keywords: 'word by word karaoke synced lyrics provider source',
  ),
  SettingsSearchEntry(
    id: 'appearance.theme',
    section: 'appearance',
    title: 'Theme',
    subtitle: 'Midnight, Pearl, or your own colours',
    keywords:
        'dark light midnight pearl custom theme background base tint '
        'accent colour color picker palette mode personalize',
  ),
  SettingsSearchEntry(
    id: 'appearance.haze',
    section: 'appearance',
    title: 'Haze material',
    subtitle: 'Blur and translucency of panels',
    keywords: 'haze blur acrylic mica glass transparency intensity solid',
  ),
  SettingsSearchEntry(
    id: 'appearance.ambient',
    section: 'appearance',
    title: 'Now Playing ambient',
    subtitle: 'Background behind the cover and lyrics',
    keywords:
        'ambient apple music winui background visualizer blur aura stage '
        'now playing lyrics colours colors',
  ),
  SettingsSearchEntry(
    id: 'appearance.surfaces',
    section: 'appearance',
    title: 'Surfaces',
    subtitle: 'Contrast and artwork tinting',
    keywords: 'amoled black dynamic artwork theme tint now playing contrast',
  ),
  SettingsSearchEntry(
    id: 'integrations.lastfm',
    section: 'integrations',
    title: 'Last.fm connection',
    subtitle: 'Scrobbling and discovery need a session',
    keywords: 'lastfm last.fm account sign in sign out session profile',
  ),
  SettingsSearchEntry(
    id: 'integrations.lastfmkeys',
    section: 'integrations',
    title: 'API keys',
    subtitle: 'Your own keys from last.fm/api/account/create',
    keywords: 'api key secret lastfm custom bring your own',
  ),
  SettingsSearchEntry(
    id: 'integrations.scrobbling',
    section: 'integrations',
    title: 'Last.fm scrobbling',
    subtitle: 'Thresholds mirror Last.fm rules',
    keywords: 'scrobble scrobbler now playing threshold percent history',
  ),
  SettingsSearchEntry(
    id: 'integrations.ytm',
    section: 'integrations',
    title: 'YouTube Music',
    subtitle: 'Personal library, history and uploads',
    keywords: 'youtube music ytm google account sign in cookies brand '
        'channel sync listening history liked songs',
  ),
  SettingsSearchEntry(
    id: 'integrations.discord',
    section: 'integrations',
    title: 'Discord',
    subtitle: 'Show what you are listening to',
    keywords: 'discord rich presence status activity',
  ),
  SettingsSearchEntry(
    id: 'about.main',
    section: 'about',
    title: 'About NeoWave',
    subtitle: 'Build and project links',
    keywords: 'version update check updates github links',
  ),
];

/// Entries matching every word of [query], title matches first. Empty
/// query returns nothing.
List<SettingsSearchEntry> filterSettings(
  List<SettingsSearchEntry> entries,
  String query, {
  int limit = 8,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  final scored = <(int, SettingsSearchEntry)>[];
  for (final entry in entries) {
    final title = entry.title.toLowerCase();
    final hay = '$title ${entry.subtitle} ${entry.keywords} ${entry.section}'
        .toLowerCase();
    if (!words.every(hay.contains)) continue;
    // Lower is better: every word in the title, then in the subtitle.
    final inTitle = words.every(title.contains);
    final inSubtitle = words.every(entry.subtitle.toLowerCase().contains);
    scored.add((inTitle ? 0 : (inSubtitle ? 1 : 2), entry));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final hit in scored.take(limit)) hit.$2];
}

/// Id of the card to flash after a jump, shared with every
/// [SettingsTarget] below it.
class SettingsSpotlight extends InheritedWidget {
  final String? activeId;
  const SettingsSpotlight({
    super.key,
    required this.activeId,
    required super.child,
  });

  static String? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsSpotlight>()
      ?.activeId;

  @override
  bool updateShouldNotify(SettingsSpotlight oldWidget) =>
      oldWidget.activeId != activeId;
}

/// Makes a settings card reachable by [id]: registers a key the page can
/// scroll to, and outlines the card while it is the spotlight. The
/// outline is painted over the card, so it changes no layout.
class SettingsTarget extends StatefulWidget {
  final String id;
  final Widget child;
  const SettingsTarget({super.key, required this.id, required this.child});

  static final keys = <String, GlobalKey>{};

  @override
  State<SettingsTarget> createState() => _SettingsTargetState();
}

class _SettingsTargetState extends State<SettingsTarget> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    SettingsTarget.keys[widget.id] = _key;
  }

  @override
  void didUpdateWidget(SettingsTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      if (SettingsTarget.keys[oldWidget.id] == _key) {
        SettingsTarget.keys.remove(oldWidget.id);
      }
      SettingsTarget.keys[widget.id] = _key;
    }
  }

  @override
  void dispose() {
    if (SettingsTarget.keys[widget.id] == _key) {
      SettingsTarget.keys.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = SettingsSpotlight.of(context) == widget.id;
    final accent = waveAccent(context);
    return AnimatedContainer(
      key: _key,
      duration: const Duration(milliseconds: 180),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(
          color: active ? accent : const Color(0x00000000),
          width: 1.5,
        ),
        color: active ? accent.withValues(alpha: 0.07) : null,
      ),
      child: widget.child,
    );
  }
}

class SettingsSearchBox extends StatefulWidget {
  final ValueChanged<SettingsSearchEntry> onPick;
  const SettingsSearchBox({super.key, required this.onPick});

  @override
  State<SettingsSearchBox> createState() => _SettingsSearchBoxState();
}

class _SettingsSearchBoxState extends State<SettingsSearchBox> {
  final _controller = TextEditingController();
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();
  final _scope = FocusScopeNode(debugLabel: "settings search results");
  final _field = FocusNode(debugLabel: "settings search field");
  String _query = '';
  bool _open = false;

  @override
  void dispose() {
    _scope.dispose();
    _field.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setOpen(bool value) {
    _open = value;
    if (value) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  void _pick(SettingsSearchEntry hit) {
    widget.onPick(hit);
    _controller.clear();
    setState(() {
      _query = '';
      _setOpen(false);
    });
  }

  /// Results float over the page (an overlay anchored under the field), so
  /// typing never pushes the settings below it down.
  Widget _results(BuildContext context, List<SettingsSearchEntry> hits, double width) {
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _group,
          child: FocusScope(
            node: _scope,
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                setState(() => _setOpen(false));
                _field.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: FocusTraversalGroup(
            child: Container(
            width: width,
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: FluentTheme.of(context).menuColor,
              borderRadius: BorderRadius.circular(WaveRadius.floating),
              border: Border.all(color: waveDivider(context)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: hits.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      'No settings match "${_query.trim()}".',
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final hit in hits)
                        ListTile(
                          title: Text(hit.title),
                          subtitle: Text(
                            '${_sectionLabel(hit.section)} · ${hit.subtitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () => _pick(hit),
                        ),
                    ],
                  ),
          ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hits = filterSettings(settingsSearchEntries, _query);
    return LayoutBuilder(
      builder: (context, constraints) => OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) =>
            _results(context, hits, constraints.maxWidth),
        child: CompositedTransformTarget(
          link: _link,
          child: TapRegion(
            groupId: _group,
            onTapOutside: (_) {
              if (_open) setState(() => _setOpen(false));
            },
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, e) {
                if (e is! KeyDownEvent || !_open) return KeyEventResult.ignored;
                final k = e.logicalKey;
                if (k == LogicalKeyboardKey.escape) {
                  setState(() => _setOpen(false));
                  return KeyEventResult.handled;
                }
                final shift = HardwareKeyboard.instance.isShiftPressed;
                if ((k == LogicalKeyboardKey.tab && !shift) ||
                    k == LogicalKeyboardKey.arrowDown) {
                  final first = _scope.traversalDescendants.firstOrNull;
                  if (first != null) {
                    first.requestFocus();
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: TextBox(
              focusNode: _field,
              controller: _controller,
              placeholder: 'Search settings',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(WaveIcons.search, size: 13),
              ),
              decoration: waveInputDecoration(context),
              foregroundDecoration: waveInputForegroundDecoration(context),
              textAlignVertical: TextAlignVertical.center,
              onTap: () {
                if (_query.trim().isNotEmpty && !_open) {
                  setState(() => _setOpen(true));
                }
              },
              onChanged: (value) => setState(() {
                _query = value;
                _setOpen(value.trim().isNotEmpty);
              }),
              // Enter opens the best match.
              onSubmitted: (_) {
                if (hits.isNotEmpty) _pick(hits.first);
              },
            ),
            ),
          ),
        ),
      ),
    );
  }
}

String _sectionLabel(String id) => switch (id) {
      _ => '${id[0].toUpperCase()}${id.substring(1)}',
    };
