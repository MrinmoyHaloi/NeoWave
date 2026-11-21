# NeoWave Desktop

Flutter desktop (Windows/Linux; macOS is not built or supported) music player in the style of Limusic. Plays **YouTube Music**
through InnerTube, scrobbles to **Last.fm**, resolves official studio artwork (iTunes/Deezer, never
YouTube video stills) and renders word-synced lyrics.

- Package `neowave`, Dart `^3.13.3`, version `0.0.1+1`. About 88k lines of code (`scc`, 2026-11-15).
- UI: `fluent_ui` (WinUI look), not Material. Playback: `media_kit` / libmpv. State: Riverpod 2.6.1.
  Routing: go_router.
- One UI stack: everything renders from `lib/ui/` (`Wave*` widgets, contract in `lib/ui/README.md`).
  Reuse business logic through Riverpod providers only. The old editorial screens, `lib/widgets/*` and
  the retired `design_system` roots are deleted; do not recreate them.

## Rules

- **Never run `dart format` / `flutter format`.** The code is not formatter-clean and it buries real
  changes. Match surrounding formatting by hand; check with `flutter analyze`.
- **Never run the full test suite.** Run specific files only.
- **Never log** URLs, cookies, tokens or auth headers. Debug `debugPrint`s stay behind `kDebugMode`.
- **Secrets:** nothing is bundled. Last.fm API key and secret are user-supplied (below). YouTube cookies
  live in the OS keychain.
- **Comments:** short and current. Say why, not what. No history ("used to", dates, removed features).
- New screens go in `lib/ui/`. Never import `package:flutter/material.dart`.
- Keep `FocusManager.highlightStrategy = alwaysTraditional` in `main.dart` (touch mode silences hover).
- Schema is created in full on open (`CREATE TABLE IF NOT EXISTS`), no versioning. Edit the `CREATE`s.
- One persistent audio-only libmpv player. `setOutputDevice` is the only output-device entry point.
  There is no limiter; gain is mpv volume.
- Document the reason in code when adding another deliberate desktop divergence.

## Layout

| Path | Purpose |
|---|---|
| `lib/app/` | router, auth gate, window, track actions |
| `lib/core/` | storage (SQLite, prefs, secure store), network, artwork, diagnostics, audio models |
| `lib/features/` | business logic (repos, APIs, providers) and the karaoke lyrics view |
| `lib/ui/` | Fluent desktop layer |
| `lib/design_system/fluent/` | `Lw*` aliases over `Wave` tokens, re-exported by `fluent.dart` |
| `linux/runner/yt_webview_guard.*` | channel that hides the YouTube login WebView |

## Startup (`lib/main.dart`)

1. `runWebViewTitleBarWidget(args)` returns early for the BotGuard poToken helper window.
2. `MediaKit.ensureInitialized()`. Player config lives in `PlaybackService.ensurePlayer`: `vo=null`,
   32 MiB demuxer buffer, disk cache, `gapless-audio=yes`, `vid=no`.
3. `sqfliteFfiInit()` (needed by `cached_network_image`).
4. `Prefs.load()` and `AppDatabase.open()` complete before `runApp` so the first frame routes right.
5. `setupWindow()`: Mica, hidden title bar (1360x860, min 1024x640), tray, global hotkeys
   Ctrl+Alt+P/N/B. On Wayland `hotkey_manager` is skipped and `CallbackShortcuts` in `WaveShell`
   handle transport. `linux/runner/my_application.cc` re-grabs GTK focus so keys reach `FlView`.
6. `ProviderScope` overrides `prefsProvider` and `databaseProvider`.

`NeoWaveApp` (`features/settings/app.dart`) warm-starts the player on a microtask. BotGuard is not
pre-warmed because it opens an extra taskbar window.

### Router and auth

`GoRouter` is driven by `AuthGate`. Last.fm sign-in is optional: signed-in users and guests
(`Prefs.isGuest`) get the shell, everyone else goes to `/welcome`. `signOutEverywhere(ref)` pauses
playback and clears profile state, leaving downloads, settings and library alone.

Routes under `WaveShell`: `/home /search /liked /albums /album/:id /artists /artist/:name
/playlists(/:id) /ytplaylist/:id /mixes /downloads /history /now /friends /profile /settings`.
Lyrics live on `/now`.

## Storage

`lib/core/storage/app_database.dart`: SQLite (WAL). Tables: `artwork_cache`,
`recommendation_exclusions`, `saved_playlists`, `downloaded_tracks`, `kv_store`, `playback_session`,
`search_history`, `stream_cache`, `match_cache`, `local_plays`, `local_folders`, `snapshot_cache`.
Caps: stream_cache 256 (expiry-pruned), match_cache 1024, search_history 25.

**Snapshot cache** (stale-while-revalidate): `snapshot_cache` is the one capped LRU store for "show
the last copy, refresh behind it". API: `cacheGet`, `cachePut`, `cacheDelete`, `cacheClear`,
`cacheStats`. Group caps: home 12, artist 150, album 200, playlist 100, library 40, lyrics 600,
lastfm 80, genre 60, default 100. Never put per-item snapshots in `kv_store` (no timestamps).
Engine: `swrLoad` + `SnapshotCodec` in `features/home/home_snapshot.dart`.
- First build of a key per session (or every build with `everyBuild`) returns the saved copy and
  refreshes in the background, then `ref.invalidateSelf()`. Later invalidations fetch for real.
- Empty or failed refreshes never replace a good copy. Values over 1.5M chars are not persisted.
  `key == null` (signed out) bypasses the cache.
- Keys are per account; albums are shared. Settings -> Cached data shows and clears groups.

In-memory only: `SearchRepository` memoizes results (10 min, 80 entries, shares in-flight futures);
`LastFmApiService.get` replays whitelisted unsigned methods (6 h catalog, 2 min per-user).

**Prefs** (`prefs.dart`, `nw_*` keys):
- Last.fm keys are bring-your-own: `nw_lastfm_api_key` and `nw_lastfm_api_secret` (Settings -> Integrations
  -> API keys). Saving different keys signs the session out. Both are excluded from backups.
- Session: `nw_sessionkey` + `nw_username` (both required). Guest mode: `nw_guest_mode`.
- Audio: `allowedQualities = [-1, 4]` (YouTube Opus / data saver), `loudnessMode` (ReplayGain).
- Playback: crossfade (default off, 3-12 s), `audioDeviceId`, `downloadLyrics`.
- Scrobbler: `enabled` (default off), `submitNowPlaying`, `scrobblePercent` 25-90.
- Appearance: `themeMode` (`custom` default, `light`, `dark`), accent color and source, `amoled`,
  haze material and intensity.

`secure_store.dart`: OS keychain with in-memory fallback. Every call is try/caught.

## Diagnostics

- `core/diagnostics/diagnostics_log.dart`: one file per run in `<appSupport>/logs/`, 5 runs x 2 MiB.
  `info()` is always on, `detail()` follows `Prefs.verboseLogs`. Lines must contain no URLs, cookies,
  headers or tokens.
- `trace_crumb.dart`: flushed crash trail at `%TEMP%/neowave/mpv-ops.log`, also forwarded to the
  session file.
- `markCleanExit()` writes `session end clean`; the next boot logs `previous_exit: clean|unclean`.
- `log_bundle.dart` zips logs plus a redacted report. UI: Settings -> General -> Diagnostics.
- `core/app_info.dart` `appVersion` is the one version string.

## Playback

`features/player/playback_service.dart`: `PlaybackService extends StateNotifier<PlayerSnapshot>`.
- **Resolution order:** local download, then YouTube, retry once, then skip. `_resolveYoutube` is
  instant when `videoId` is set; otherwise one search (`findBestMatchOrNull`, 8 s) and the id is
  written back to the queue entry. A generation counter (`_resolveGeneration`) discards stale work.
- **Queue:** play/queue ops, shuffle (current pinned at index 0), repeat, speed steps, sleep timer,
  endless radio refill at <=6 left (filters mashups and compilations).
- **Prefetch:** neighbors are warmed after the current track's first audio tick and serialized on
  `_prefetchChain`; the `next+1` slot is lookahead-only (past 55% or <28 s left). Concurrent
  speculative resolves used to delay the current track's first audio, so keep them serial.
- **Session persistence:** `_persistNow` (2 s throttle) saves a queue window into `playback_session`.
  `toggle()` and `playResume()` re-resolve a restored track that has no mpv source yet.
- **Scrobbling** is window-based: `_beginScrobbleWindow` flushes the old window and arms a new one;
  `_tickScrobble` fires at `min(duration * scrobblePercent / 100, 240 s)` clamped to 30-240 s;
  `_flushScrobble` is idempotent.
- **Crossfade** uses a second standby player (`_armStandbyForNext`, `_startCrossfade`, watchdog and
  fault budget in `deck_guard.dart`). It falls back to gapless after repeated faults.
- Audio filters: the equalizer graph is the only `af` chain; `isFilterGraphError` stops a rejected
  filter from being treated as a broken stream.

`audio_output/output_controller.dart` lists mpv devices and stores the choice in `nw_audio_device_id`
(`auto` = system default). Device name is the key (for example `wasapi/{id}`).

Now playing is `lib/ui/now_playing/now_playing_page.dart`.

## YouTube Music (InnerTube)

`features/innertube/innertube_api.dart` (`InnerTubeMusicApi`).
- **Config:** API key and client version scraped from music.youtube.com, cached as `yt_web_config`
  (refreshed after 24 h), with fallbacks in code.
- **Clients:** `playerClients` profiles; direct-URL clients first, ciphered web clients last.
  `_fastPreferredClient = 'ANDROID'`, at most 3 clients per attempt, 8 s timeout each, 60 s cooldown
  after a failure, 4 h stream TTL, 2 min expiry margin. The first usable audio URL wins.
- **Lazy aux:** `ensureAux()` (base.js decipher, poToken) only runs when a ciphered client is reached,
  so the common path opens no WebView.
- **Format fit:** progressive before adaptive, then bitrate descending; codec must match container.
  No blocking probes: mpv is the validity check, and `reportPlaybackFailure` cools the client.
- **Decipher:** `signature_decipher.dart` is a Dart interpreter over base.js (`s` and `n` functions).
- **poToken:** `potoken_engine.dart` runs BotGuard in a hidden WebView (`assets/po_token.html`) over a
  polling bridge. Fail-open: direct clients do not need tokens.
- **Matching:** normalized token-Dice scoring with exact-title and exact-artist bonuses and variant
  penalties, cached in memory and `match_cache`. `album_match.dart` picks the correct album.
- **Browse and search:** songs, artists, albums, playlists, suggestions, radio via `/next`,
  continuation walking, `fetchPlaylist` (auth first, then anonymous; `VL`-prefix and `RDCLAK`
  handling with a `www.youtube.com` fallback).
- **Accounts:** `innerTubeProvider` restores cookies, the profile roster and the active pointer.
  `connectAs()` normalizes any cookie format, requires SAPISID and verifies before replacing the old
  session. `ytConnectionProvider` is what the UI watches. In-app sign-in is `YtWebLogin`
  (`yt_web_login.dart`); multiple Google accounts and brand channels share one jar per login and are
  routed per request with `X-Goog-PageId`.
- **Library surfaces** (`yt_library_providers.dart`, empty when signed out): liked songs, history,
  account playlists, `/ytplaylist/:id`.
- **WebView on Linux:** `desktop_webview_window` 0.3.0 crashes on destroy and has no hide API there.
  `YtWebLogin` keeps one cached window, never calls `close()`, and hides it through the
  `neowave/yt_webview` channel (`yt_webview_guard.dart`).

## Downloads

`features/downloads/download_manager.dart`: YouTube only, Opus first, AAC fallback, optional `.lrc`
sidecar, files under `~/Music/NeoWave`, registry in `downloaded_tracks`. `localPathFor` verifies the
file exists; playback prefers it.

## Last.fm

- `auth_repository.dart`: web handshake with the user's own key (`auth.getToken`, browser approval,
  `auth.getSession`).
- `scrobble_repository.dart`: 700 ms write pace, now-playing dedupe, offline queue (cap 200).
  `_signed` drops empty values (an empty `album=` breaks `api_sig`).
- `home_repository.dart`: recent tracks, stats, top lists, friends.
- `core/network/lastfm_api.dart` and `lastfm_crypto.dart`: unsigned GET, signed POST (MD5).
- `rate_guard.dart` and `dio_factory.dart`: shared Dio (desktop UA, 15 s timeouts), 429/503 backoff.
- `network_monitor.dart`: DNS poll, no `connectivity_plus`.

## Artwork

- `artwork_resolver.dart` is the only place artwork URLs are normalized, sized and ordered. YouTube
  CDNs are fallback, official CDNs are primary.
- `official_artwork_service.dart`: 1400px covers and artist photos from iTunes and Deezer in
  parallel. Never falls back to YouTube stills. Strict scoring, no substring matches, versioned cache
  keys. iTunes 403/429 pauses it for 15 min.
- Animated artwork (`animated_artwork_*`, `*_canvas.dart`): hardware acceleration stays off unless
  built with `--dart-define=NW_ARTWORK_HW=true` (the hardware path crashed on skip).

## Lyrics

`features/lyrics/lyrics_repository.dart` races LRCLIB and Apple Music word-by-word (via
`lyrics.paxsenix.org`). Rank: word-synced, then synced, then unsynced; curated beats crowdsourced;
a candidate needs 1.3x the line count to win. Matching is strict ("Song" must not match
"Song (Interlude)"). `lyrics_models.dart` holds the karaoke utilities and parsers. Rendering is
`karaoke_lyrics_view.dart`. Per-track offset is persisted.

## Feed and search

- `feed_repository.dart`: home feed from Last.fm affinity plus YouTube radio and charts, scored and
  diversified (max 2 per artist). `fetchMix` powers Mix Lab.
- `search_repository.dart`: YouTube Music for content, Last.fm for users; SQLite history (cap 25).

## UI conventions

- **Shell:** `WaveShell` (`ui/app_shell/app_shell.dart`): title bar, side rail, content capped at
  1280px, bottom `WavePlayerDock`, slide-over queue and equalizer panels. Ctrl+K palette, Ctrl+F
  search, Ctrl+L / dock button opens Now Playing. Arrow-key handling is in `wave_hotkeys.dart`.
- **Now playing:** two columns (media, karaoke lyrics), controls auto-hide after 3.5 s, F11 fullscreen.
  Put any `ref.listen` at the top of `build()`, never inside a `Builder`.
- **Menus:** `WaveFlyoutPanel` is the only menu surface. Submenus are `OverlayPortal` children of
  their row, not second routes. Never use `dismissOnPointerMoveAway`.
- **Scrolling:** scrollbars come only from `WaveScrollBehavior`; never wrap a scrollable in `Scrollbar`.
  `SelectableText` needs `contextMenuBuilder: TextBox.defaultContextMenuBuilder`.
- **Theme:** tokens in `ui/theme/tokens.dart`; `fluent_theme.dart` builds the swatch. The AMOLED/Custom
  base is read with `waveSurfaces(context)` (`WaveSurfacesScope`).
- **Material:** the only Material imports are narrow `show` lists for `ReorderableListView` in
  `home_layout_page.dart` and `queue_panel.dart`.
- **Shared widgets** (`ui/components/`): `WaveArtwork` (use `upgrade: false` for avatars),
  `WaveIconButton`, `waveTrackMenuItems`, `WaveDesktopTable` (virtualized, no 2-D scrollables),
  `WaveCommandBar`, `WaveLoading/Empty/Error`, skeletons.
- **Pages:** Consumer widgets, staggered `WaveEntrance`, skeletons instead of spinners. Artwork only
  through `WaveArtwork`. Read animated widths with `LayoutBuilder`, not a flipping boolean.
- Accepted leak: `home_page.dart` and `discover_page.dart` use `palette_generator` directly.

## Tests

Run specific files, for example `flutter test test/core_test.dart`. Do not run the whole suite.
Live tests need network and are run explicitly: `innertube_live_test.dart`
(`--timeout 300s`), `playback_live_test.dart` (Windows plus `LIVE_PLAYBACK`),
`playback_service_live_test.dart`, `probe_test.dart`.

## Tooling

- Lint: `flutter_lints`; `build/`, `windows/`, `macos/`, `linux/` excluded.
- CI: `.github/workflows/desktop.yml` builds Linux and Windows (deb/rpm and the Windows installer on `v*` tags; the Linux AppImage and Windows portable zip steps are commented out, search `DISABLED`). macOS is not built; the `macos/` folder is just the stock template.
- Linux build deps: `libmpv-dev`, `libayatana-appindicator3-dev`, `libasound2-dev`,
  `libkeybinder-3.0-dev`. Windows bundles `libmpv-2.dll` through `media_kit`.
