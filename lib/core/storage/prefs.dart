
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings + session persistence.
///
/// Keys use the `nw_*` prefix (NeoWave short form).
class Prefs {
  final SharedPreferences _sp;
  Prefs(this._sp);

  static Future<Prefs> load() async =>
      Prefs(await SharedPreferences.getInstance());

  // -- Last.fm BYOK (bring your own keys) ---------------------------------
  // No bundled API keys ship with the app: the user enters their own
  // Last.fm API key + shared secret (from last.fm/api/account/create),
  // stored here in SharedPreferences. All Last.fm features stay
  // disabled until both are set.
  String get lastFmApiKey => _sp.getString('nw_lastfm_api_key') ?? '';
  String get lastFmApiSecret => _sp.getString('nw_lastfm_api_secret') ?? '';
  bool get isLastFmConfigured =>
      lastFmApiKey.isNotEmpty && lastFmApiSecret.isNotEmpty;

  Future<void> saveLastFmKeys({
    required String apiKey,
    required String apiSecret,
  }) async {
    await _sp.setString('nw_lastfm_api_key', apiKey);
    await _sp.setString('nw_lastfm_api_secret', apiSecret);
  }

  Future<void> clearLastFmKeys() async {
    await _sp.remove('nw_lastfm_api_key');
    await _sp.remove('nw_lastfm_api_secret');
  }

  // -- Guest mode (keyless entry) -------------------------------------------
  // Set by the welcome Skip button: the user enters the shell without
  // Last.fm keys or session. Everything except Last.fm features works;
  // reconnect happens in Settings only. Sticky across restarts; cleared
  // by full sign-out and by saving a real session.
  bool get isGuest => _sp.getBool('nw_guest_mode') ?? false;
  Future<void> setGuestMode(bool v) =>
      _sp.setBool('nw_guest_mode', v);

  // -- Last.fm session (web auth under the user's own API key) ------------
  // Authentication is compulsory: there is no guest or anonymous mode.
  // A session is valid only when both the username and the session key
  // are stored. Session keys are bound to the API key that minted them,
  // so saving different API keys signs the session out (see
  // AuthRepository.saveCustomKeys).
  String get sessionKey => _sp.getString('nw_sessionkey') ?? '';
  String get username => _sp.getString('nw_username') ?? '';
  bool get isAuthenticated => username.isNotEmpty && sessionKey.isNotEmpty;

  Future<void> saveSession({
    required String sessionKey,
    required String username,
  }) async {
    await _sp.setString('nw_sessionkey', sessionKey);
    await _sp.setString('nw_username', username);
    await _sp.remove('nw_guest_mode');
  }

  Future<void> signOut() async {
    await _sp.remove('nw_sessionkey');
    await _sp.remove('nw_username');
    await _sp.remove('nw_guest_mode');
  }

  // -- Audio quality (mirrors Android quality tiers) ---------------------
  /// -1 = YouTube Opus (default), 4 = data saver (playback prefers the
  /// smallest YouTube audio). Anything else saved earlier falls back to -1.
  static const allowedQualities = [-1, 4];

  int get streamQuality =>
      _clampQuality(_sp.getInt('nw_stream_quality') ?? -1);
  int get downloadQuality =>
      _clampQuality(_sp.getInt('nw_download_quality') ?? -1);

  static int _clampQuality(int q) => allowedQualities.contains(q) ? q : -1;

  Future<void> setStreamQuality(int q) =>
      _sp.setInt('nw_stream_quality', _clampQuality(q));
  Future<void> setDownloadQuality(int q) =>
      _sp.setInt('nw_download_quality', _clampQuality(q));
  // -- Window behaviour ---------------------------------------------------
  /// Close button / Alt+F4 hides to the tray instead of quitting.
  /// Real quit stays in tray → Quit (ordered player teardown first).
  /// Default off (clicking X closes the application and stops audio).
  bool get closeToTray =>
      _sp.getBool('nw_close_to_tray') ?? false;
  Future<void> setCloseToTray(bool v) =>
      _sp.setBool('nw_close_to_tray', v);

  // -- Playback behaviour -------------------------------------------------
  /// Keep playing similar tracks (endless radio) after a queue runs
  /// out. Default on — matches Spotify/YTM autoplay behaviour.
  bool get autoplaySimilar =>
      _sp.getBool('nw_autoplay_similar') ?? true;
  Future<void> setAutoplaySimilar(bool v) =>
      _sp.setBool('nw_autoplay_similar', v);

  bool get crossfadeEnabled => _sp.getBool('nw_crossfade_enabled') ?? false;
  int get crossfadeSeconds {
    final v = _sp.getInt('nw_crossfade_seconds') ?? 5;
    return v.clamp(3, 12);
  }

  Future<void> setCrossfade(bool enabled, [int? seconds]) async {
    await _sp.setBool('nw_crossfade_enabled', enabled);
    if (seconds != null) {
      await _sp.setInt('nw_crossfade_seconds', seconds.clamp(3, 12));
    }
  }

  Future<void> setCrossfadeSeconds(int seconds) async {
    await _sp.setInt('nw_crossfade_seconds', seconds.clamp(3, 12));
  }

  /// mpv device name; empty = system default output.
  String get audioDeviceId => _sp.getString('nw_audio_device_id') ?? '';
  Future<void> setAudioDeviceId(String v) =>
      _sp.setString('nw_audio_device_id', v);

  /// Each playlist's last track sort, as `<sort>:<asc|desc>` (like the
  /// phone app), kept until the user picks another one.
  String playlistSort(int id) =>
      _sp.getString('nw_playlist_sort_$id') ?? 'default:asc';
  Future<void> setPlaylistSort(int id, String v) =>
      _sp.setString('nw_playlist_sort_$id', v);

  // -- Loudness (ReplayGain, not a file scan) ------------------------------
  /// `off`, `track`, or `album`.
  String get loudnessMode {
    final raw = (_sp.getString('nw_loudness_mode') ?? 'off').toLowerCase();
    if (raw == 'track' || raw == 'album') return raw;
    return 'off';
  }

  Future<void> setLoudnessMode(String mode) {
    final raw = mode.toLowerCase();
    final stored = (raw == 'track' || raw == 'album') ? raw : 'off';
    return _sp.setString('nw_loudness_mode', stored);
  }

  bool get downloadLyrics => _sp.getBool('nw_download_lyrics') ?? true;
  Future<void> setDownloadLyrics(bool v) =>
      _sp.setBool('nw_download_lyrics', v);

  /// Custom download folder. Empty = default (`Music/NeoWave`, else
  /// app documents). Set via Settings → Downloads or the Downloads
  /// page; changeable at any time, applies to new downloads.
  String get downloadDir => _sp.getString('nw_download_dir') ?? '';
  Future<void> setDownloadDir(String v) =>
      _sp.setString('nw_download_dir', v.trim());
  Future<void> resetDownloadDir() =>
      _sp.remove('nw_download_dir');

  // -- Lyrics --------------------------------------------------------------
  bool get wordByWord => _sp.getBool('nw_word_by_word') ?? true;
  Future<void> setWordByWord(bool v) => _sp.setBool('nw_word_by_word', v);

  /// Primary lyrics provider id (`auto` default). Explicit picks get a
  /// head start; the rest of the chain stays as automatic fallback.
  String get lyricsProviderId =>
      _sp.getString('nw_lyrics_provider') ?? 'auto';
  Future<void> setLyricsProviderId(String v) =>
      _sp.setString('nw_lyrics_provider', v);

  /// Multiplier on the lyrics type size. Snapped to the steps the
  /// lyrics view and Settings both offer.
  static const lyricsTextScales = <(double, String)>[
    (0.85, 'Small'),
    (1.0, 'Medium'),
    (1.2, 'Large'),
    (1.4, 'Extra large'),
    (1.6, 'Huge'),
  ];

  double get lyricsTextScale => _nearestDouble(
        _sp.getDouble('nw_lyrics_text_scale') ?? 1.0,
        [for (final step in lyricsTextScales) step.$1],
      );

  Future<void> setLyricsTextScale(double v) => _sp.setDouble(
        'nw_lyrics_text_scale',
        _nearestDouble(v, [for (final step in lyricsTextScales) step.$1]),
      );

  /// `off` or a short language code. Lyric sources in this app do not
  /// return a translation; the choice is stored for the lyrics view.
  static const lyricsTranslationOptions = <String, String>{
    'off': 'Off',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'pt': 'Portuguese',
    'hi': 'Hindi',
    'ja': 'Japanese',
    'ko': 'Korean',
  };

  String get lyricsTranslationLang {
    final v = _sp.getString('nw_lyrics_translation') ?? 'off';
    return lyricsTranslationOptions.containsKey(v) ? v : 'off';
  }

  Future<void> setLyricsTranslationLang(String v) => _sp.setString(
        'nw_lyrics_translation',
        lyricsTranslationOptions.containsKey(v) ? v : 'off',
      );

  /// `0` keeps the lyrics toolbar visible. Otherwise idle seconds
  /// before it fades (2–10).
  static const lyricsAutoHideOptions = <int, String>{
    0: 'Always on',
    2: '2 seconds',
    4: '4 seconds',
    6: '6 seconds',
    8: '8 seconds',
    10: '10 seconds',
  };

  int get lyricsAutoHideSeconds {
    final v = _sp.getInt('nw_lyrics_autohide_seconds') ?? 0;
    if (v <= 0) return 0;
    return _nearestInt(v, const [2, 4, 6, 8, 10]);
  }

  Future<void> setLyricsAutoHideSeconds(int seconds) {
    final v = seconds <= 0 ? 0 : _nearestInt(seconds, const [2, 4, 6, 8, 10]);
    return _sp.setInt('nw_lyrics_autohide_seconds', v);
  }

  static double _nearestDouble(double value, Iterable<double> steps) {
    var best = steps.first;
    var bestDist = double.infinity;
    for (final step in steps) {
      final dist = (step - value).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = step;
      }
    }
    return best;
  }

  static int _nearestInt(int value, List<int> steps) {
    var best = steps.first;
    var bestDist = 1 << 30;
    for (final step in steps) {
      final dist = (step - value).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = step;
      }
    }
    return best;
  }

  // -- Appearance ------------------------------------------------------------
  bool get amoled => _sp.getBool('nw_amoled') ?? false;
  Future<void> setAmoled(bool v) => _sp.setBool('nw_amoled', v);

  /// 'dark' (midnight observatory), 'light' (pearl white) or 'custom'
  /// (surfaces generated from [customThemeBase]).
  ///
  /// Defaults to 'custom' on the sky-blue base below: a pale, blue-tinted
  /// light theme rather than the midnight one.
  String get themeMode => _sp.getString('nw_theme_mode') ?? 'custom';
  Future<void> setThemeMode(String v) => _sp.setString('nw_theme_mode', v);
  bool get isLight => themeMode == 'light';
  bool get isCustomTheme => themeMode == 'custom';

  /// Base colour (ARGB) of the Custom theme. Default: #04041C, a near-black
  /// navy; [WaveSurfaces.fromCustomBase] lifts it into a dark surface ramp.
  int get customThemeBase => _sp.getInt('nw_custom_theme_base') ?? 0xFF04041C;
  Future<void> setCustomThemeBase(int v) =>
      _sp.setInt('nw_custom_theme_base', v);

  /// Accent colour. Default: sky blue.
  int get accentColor => _sp.getInt('nw_accent') ?? 0xFF38BDF8;
  Future<void> setAccentColor(int v) => _sp.setInt('nw_accent', v);

  bool get dynamicNowPlaying => _sp.getBool('nw_dynamic_now_playing') ?? false;
  Future<void> setDynamicNowPlaying(bool v) =>
      _sp.setBool('nw_dynamic_now_playing', v);

  // -- Haze / material (spec §42 — only settings that actually work) ------
  /// 'automatic' | 'haze' | 'solid'. Solid disables BackdropFilter
  /// everywhere (static tonal fallback); automatic uses Haze L1–L3 as
  /// designed, honouring reduce-transparency.
  String get hazeMaterial => _sp.getString('nw_haze_material') ?? 'automatic';
  Future<void> setHazeMaterial(String v) =>
      _sp.setString('nw_haze_material', v);

  /// 'low' | 'medium' | 'high'. Scales L1–L3 blur sigma.
  String get hazeIntensity => _sp.getString('nw_haze_intensity') ?? 'medium';
  Future<void> setHazeIntensity(String v) =>
      _sp.setString('nw_haze_intensity', v);

  /// Accent source: 'system' | 'neowave' | 'artwork' | 'custom'.
  /// 'manual' is treated as 'custom'. The theme controller resolves the effective accent; artwork mode tints from the current
  /// palette seed where available, otherwise falls back to custom.
  String get accentSource {
    final v =
        _sp.getString('nw_accent_source') ??
        _sp.getString('nw_accent_mode') ??
        'custom';
    if (v == 'manual') return 'custom';
    return v;
  }

  Future<void> setAccentSource(String v) async {
    await _sp.setString('nw_accent_source', v);
    await _sp.setString('nw_accent_mode', v);
  }


  // -- Scrobbler --------------------------------------------------------------
  bool get scrobblerEnabled => _sp.getBool('nw_scrobbler_enabled') ?? false;
  bool get scrobbleNowPlaying => _sp.getBool('nw_submit_now_playing') ?? true;
  int get scrobblePercent {
    final v = _sp.getInt('nw_scrobble_percent') ?? 50;
    return v.clamp(25, 90);
  }

  Future<void> setScrobbler({
    bool? enabled,
    bool? nowPlaying,
    int? percent,
  }) async {
    if (enabled != null) {
      await _sp.setBool('nw_scrobbler_enabled', enabled);
    }
    if (nowPlaying != null) {
      await _sp.setBool('nw_submit_now_playing', nowPlaying);
    }
    if (percent != null) {
      await _sp.setInt('nw_scrobble_percent', percent.clamp(25, 90));
    }
  }

  // -- YouTube Music --------------------------------------------------------
  /// Push played tracks into the account's YT Music watch history.
  /// Default off: writing to the Google account is opt-in.
  bool get syncYtHistory => _sp.getBool('nw_sync_yt_history') ?? true;

  /// Two-way YouTube Music sync of Liked Songs and playlists.
  bool get syncYtLibrary => _sp.getBool('nw_sync_yt_library') ?? true;

  Future<void> setSyncYtLibrary(bool v) =>
      _sp.setBool('nw_sync_yt_library', v);

  Future<void> setSyncYtHistory(bool v) =>
      _sp.setBool('nw_sync_yt_history', v);

  /// Skip BotGuard poToken minting entirely (direct-URL clients only).
  /// Default off (poTokens enabled). Escape hatch for machines where the
  /// hidden `NeoWave BotGuard` WebView misbehaves: playback then never
  /// opens a WebView and fails open to direct streams; some
  /// ciphered-only tracks may not resolve.
  bool get disablePoToken => _sp.getBool('nw_disable_potoken') ?? false;

  Future<void> setDisablePoToken(bool v) =>
      _sp.setBool('nw_disable_potoken', v);

  // -- Desktop-app Parity (Karaoke Lyrics & Visualizer & CD Mode) ------------
  int getLyricsOffset(String trackKey) =>
      _sp.getInt('nw_lyrics_offset_$trackKey') ?? 0;

  Future<void> setLyricsOffset(String trackKey, int offsetMs) =>
      _sp.setInt('nw_lyrics_offset_$trackKey', offsetMs);

  Future<void> resetLyricsOffset(String trackKey) =>
      _sp.remove('nw_lyrics_offset_$trackKey');

  bool get lyricsTransliteration =>
      _sp.getBool('nw_lyrics_transliteration') ?? true;

  Future<void> setLyricsTransliteration(bool v) =>
      _sp.setBool('nw_lyrics_transliteration', v);

  bool get visualizerEnabled => _sp.getBool('nw_visualizer_enabled') ?? true;

  Future<void> setVisualizerEnabled(bool v) =>
      _sp.setBool('nw_visualizer_enabled', v);

  /// Now Playing ambient style: 'apple' (vivid artwork colours, always on
  /// a dark stage with white text, the same in every theme) or 'winui'
  /// (the calm tonal stage that follows the app theme).
  String get ambientStyle => _sp.getString('nw_ambient_style') ?? 'apple';
  Future<void> setAmbientStyle(String v) =>
      _sp.setString('nw_ambient_style', v);

  // -- Discord Rich Presence --------------------------------------------------
  /// Show the current track in Discord status. Default on.
  bool get discordRichPresence =>
      _sp.getBool('nw_discord_rich_presence') ?? true;

  Future<void> setDiscordRichPresence(bool v) =>
      _sp.setBool('nw_discord_rich_presence', v);

  // -- Diagnostics -----------------------------------------------------------
  /// Per-request detail in the session log (stream clients, audio probes).
  /// Off by default: the always-on lines already name every stage, and
  /// verbose adds a few lines per player request.
  bool get verboseLogs => _sp.getBool('nw_verbose_logs') ?? false;

  Future<void> setVerboseLogs(bool v) => _sp.setBool('nw_verbose_logs', v);

  // -- Equalizer & Studio Master Clarity ------------------------------------
  bool get equalizerEnabled => _sp.getBool('nw_eq_enabled') ?? false;
  Future<void> setEqualizerEnabled(bool v) => _sp.setBool('nw_eq_enabled', v);

  String get equalizerPreset => _sp.getString('nw_eq_preset') ?? 'Default';
  Future<void> setEqualizerPreset(String v) =>
      _sp.setString('nw_eq_preset', v);

  String get equalizerGains => _sp.getString('nw_eq_gains') ?? '';
  Future<void> setEqualizerGains(String v) =>
      _sp.setString('nw_eq_gains', v);

  bool get studioClarityEnabled =>
      _sp.getBool('nw_studio_clarity_enabled') ?? false;
  Future<void> setStudioClarityEnabled(bool v) =>
      _sp.setBool('nw_studio_clarity_enabled', v);

  String get studioClarityPreset =>
      _sp.getString('nw_studio_clarity_preset') ?? 'reference';
  Future<void> setStudioClarityPreset(String v) =>
      _sp.setString('nw_studio_clarity_preset', v);

  // -- App Updates ------------------------------------------------------------
  /// GitHub release version the user opted to suppress automatic startup popups for.
  String get ignoredUpdateVersion =>
      _sp.getString('nw_ignored_update_version') ?? '';

  Future<void> setIgnoredUpdateVersion(String v) =>
      _sp.setString('nw_ignored_update_version', v);

  Future<void> clearIgnoredUpdateVersion() =>
      _sp.remove('nw_ignored_update_version');
  
  // -- Download folder layout (Android DownloadFolderStructure ids) ---------
  String get downloadStructure {
    final raw = _sp.getString('nw_download_structure') ?? 'flat';
    const known = {
      'flat',
      'artist_album',
      'artist_year_album',
      'album_only',
      'year_album',
    };
    return known.contains(raw) ? raw : 'flat';
  }

  Future<void> setDownloadStructure(String id) =>
      _sp.setString('nw_download_structure', id);

  // -- Portable backup (non-secret prefs only) ------------------------------
  static bool isSecretPref(String key) {
    final k = key.toLowerCase();
    const exact = {
      'nw_sessionkey',
      'nw_lastfm_api_key',
      'nw_lastfm_api_secret',
      'nw_apikey',
      'nw_apisecret',
      // Addon tokens stored by older builds: never written into a backup.
      'nw_addon_url',
      'nw_addon_urls',
      'ytm_cookies',
    };
    if (exact.contains(k)) return true;
    if (k.contains('cookie')) return true;
    if (k.contains('secret')) return true;
    if (k.contains('sp_dc')) return true;
    if (k.contains('sessionkey')) return true;
    return false;
  }

  /// Settings that only make sense on the machine they were set on (a
  /// folder path, an audio device id, the signed-in name).
  static bool isDeviceBoundPref(String key) => const {
        'nw_download_dir',
        'nw_audio_device_id',
        'nw_username',
      }.contains(key.toLowerCase());

  static bool _isPortable(String key) =>
      !isSecretPref(key) && !isDeviceBoundPref(key);

  Set<String> get portablePrefKeys =>
      _sp.getKeys().where(_isPortable).toSet();

  Object? portablePref(String key) =>
      _isPortable(key) ? _sp.get(key) : null;

  Future<void> setPortablePref(String key, Object value) async {
    if (!_isPortable(key)) return;
    if (value is bool) {
      await _sp.setBool(key, value);
    } else if (value is int) {
      await _sp.setInt(key, value);
    } else if (value is double) {
      await _sp.setDouble(key, value);
    } else if (value is String) {
      await _sp.setString(key, value);
    } else if (value is List) {
      await _sp.setStringList(
        key,
        value.map((e) => e.toString()).toList(),
      );
    }
  }
}

final prefsProvider = Provider<Prefs>((_) {
  throw UnimplementedError('Prefs not initialised — override in main()');
});
