import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/audio/stream_models.dart';
import '../../core/diagnostics/trace_crumb.dart';
import '../../core/platform/allocator_tuning.dart';
import 'loudness.dart';
import 'deck_guard.dart';
import '../downloads/download_manager.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/scrobble_repository.dart';
import 'mpv_paths.dart';
import 'player_state.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart';
import '../../core/error/fatal_crumbs.dart';

/// Desktop playback service built on media_kit (MPV).
///
/// Product behaviour:
/// - local download → YouTube → retry → skip
/// - queue with shuffle/repeat/speed/sleep, endless radio refill
/// - session persistence + scrobble thresholds
/// - stream failure backoff (client cooldown + unavailable set)
/// True for an mpv error that means an `af` graph (the EQ) was
/// rejected, as opposed to a stream that cannot be played.
bool isFilterGraphError(String text) {
  final t = text.toLowerCase();
  return t.contains('audio filter') ||
      t.contains('filter graph') ||
      t.contains('filtergraph') ||
      t.contains('lavfi') ||
      t.contains('af:');
}

class PlaybackService extends StateNotifier<PlayerSnapshot> {
  final InnerTubeMusicApi _tube;
  final ScrobbleRepository _scrobbler;
  final DownloadManager _downloads;
  final PrefsHandle _prefs;
  final SessionStore _sessions;
  final OfficialArtworkService _artworkService;

  Player? _player;
  final List<StreamSubscription> _subs = [];
  final List<PlayerLog> _mpvLogTail = [];
  static const int _mpvLogTailMax = 50;
  final Set<String> _unavailable = {};
  List<int> _shuffleOrder = [];
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  Timer? _persistThrottle;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // UI position emission gate: mpv fires time-pos per frame (60Hz+)
  // and every emission rebuilds all position watchers (dock bar,
  // karaoke, time labels, mini player). Karaoke interpolates
  // wall-clock between updates and bars read smooth at 10Hz, so the
  // state snapshot is throttled. Scrobble uses wall-clock deltas so
  // 10Hz keeps identical accuracy; prefetch fires once per track.
  DateTime _lastPositionEmit = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBufferedEmit = DateTime.fromMillisecondsSinceEpoch(0);

  // Scrobble bookkeeping (mirrors Android detector).
  int _scrobbleStartEpoch = 0;
  double _accumulatedSeconds = 0;
  DateTime? _lastTick;
  bool _nowPlayingSent = false;
  PlayableTrack? _scrobbleTrack;
  int _scrobbleDurationSec = 0;
  bool _scrobbledThisWindow = false;
  // YT Music history push shares the scrobble window: a single ping
  // per window, fired alongside the scrobble, gated by the settings
  // flag. Repeats would file duplicate entries.
  bool _ytHistoryPushedThisWindow = false;
  // Pushes started this window. Failures re-arm the flag for the flush
  // site's retry, so this cap bounds the retries; without it a rejected
  // ping re-fired on every position tick for the whole track.
  int _ytHistoryAttempts = 0;
  // One client playback nonce per scrobble window.
  String _ytHistoryCpn = '';
  // Pre-signed watchtime bases by videoId (from the player response
  // that resolved the stream). Memory-only, capped: tokens are bound
  // to the live session.
  final Map<String, String> _watchtimeUrls = {};

  void _stashWatchtimeUrl(String videoId, String url) {
    try {
      if (videoId.isEmpty || url.isEmpty) return;
      _watchtimeUrls.remove(videoId);
      _watchtimeUrls[videoId] = url;
      while (_watchtimeUrls.length > 24) {
        _watchtimeUrls.remove(_watchtimeUrls.keys.first);
      }
    } catch (_) {}
  }

  void _rememberWatchtime(String videoId, ResolvedStream stream) {
    _stashWatchtimeUrl(videoId, stream.watchtimeUrl);
  }

  bool _endlessRadio = false;
  final Set<String> _radioSeeds = {};
  bool _resolving = false;
  int _resolvingIndex = -1;
  int _resolveGeneration = 0;
  int _playbackAttempt = 0;
  int _failedGeneration = -1;
  String _activeQueueKey = '';
  final ResolvedStreamCache _playCache = ResolvedStreamCache();
  final Map<String, Future<ResolvedStream?>> _resolveInflight = {};
  final Set<String> _prefetchInflight = {};
  String _prefetchSeedKey = '';
  /// Speculative resolves are chained, never parallel. Three concurrent
  /// DASH assemblies (prev + next + next+1, ~35 MB each) pushed the
  /// playing track's first byte to 1.4-1.8s and its assembly 8-10s out
  /// (measured); one at a time keeps the link for the track
  /// the user is actually hearing.
  Future<void> _prefetchChain = Future<void>.value();

  // -- first-audio clock (debug timing only) -------------------------------
  //
  // `open()` returning — and even `playing=true` — is NOT audible sound.
  // mpv flips pause=no (media_kit's `playing`) as soon as loadfile is
  // accepted, then prerolls cache (`paused-for-cache`) before the first
  // frame renders. The only signal close to "sound coming out" is the
  // position clock advancing past zero, so that's what arms this clock:
  // resolve-start → first position > 0 for the same generation.
  DateTime? _audioClockStart;
  String _audioClockKey = '';
  int _audioClockGeneration = -1;
  DateTime? _audioOpenDoneAt;

  // -- native mpv serialization -------------------------------------------
  //
  // Windows libmpv corrupts its heap when stop/open/property writes
  // overlap: the first track plays, the next transition dies in ntdll
  // with 0xc0000005 and no Dart log (the await never returns). Every
  // stream-lifecycle native call goes through [_serializedMpv] so only
  // one is ever in flight. Hot-path transport (seek/volume/rate) stays
  // direct — serializing those would queue-jank playback.
  Future<void> _mpvTail = Future.value();

  Future<T> _serializedMpv<T>(Future<T> Function() op) {
    final run = _mpvTail.then((_) => op());
    _mpvTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// True when mpv currently holds a DASH manifest. DASH teardown on
  /// Windows lags the stop call (segment fetches still in flight), so
  /// the next open waits for idle first — otherwise loadfile races
  /// the dying demuxer and corrupts the heap.
  bool _lastWasDash = false;
  String _eqFilter = '';
  // Set when mpv rejected the EQ graph (missing FFmpeg filter):
  // processing stays off for the rest of the session.
  bool _processingDisabled = false;
  String _currentAudioFilter = '';
  String _currentAudioDevice = 'auto';
  /// Album ReplayGain (dB, before the -14 LUFS preamp) shared by the
  /// current album when libmpv reports the same tag twice. NaN means
  /// the tags disagreed, so untagged siblings use the fixed fallback.
  final Map<String, double> _albumReplayGainDb = {};
  bool get _preferSmallestYoutube =>
      _prefs.streamQuality == AudioQualityTiers.dataSaver;

  bool get _overlapEnabled =>
      _prefs.crossfadeEnabled && _mixFaults.overlapAllowed;

  Duration _overlapLength() =>
      Duration(seconds: _prefs.crossfadeSeconds.clamp(3, 12));

  /// Overlap for the pair that is about to mix.
  Duration _currentOverlap() => _overlapLength();

  // -- Dual-engine Crossfade & Standby state -------------------------------
  Player? _standbyPlayer;
  bool _standbyArmed = false;

  /// True only once the standby deck has the next track fully opened and
  /// prepared. The overlap never starts before this: starting it on a deck
  /// that is still loading degrades into a hard cut
  /// followed by the new track starting over.
  bool _standbyReady = false;

  /// Track whose overlap was abandoned (deck not ready in time), so it is
  /// not re-armed every tick — that track falls back to a gapless change.
  String _mixGaveUpFor = '';

  /// How long before the overlap window the standby deck is loaded.
  static const Duration _armLead = Duration(seconds: 14);
  PlayableTrack? _standbyTrack;
  ResolvedStream? _standbyStream;
  int _standbyIndex = -1;
  bool _crossfading = false;
  DateTime? _crossfadeStartTime;
  Duration? _crossfadeDuration;
  Timer? _crossfadeTimer;
  double _crossfadeTargetVolume = 1.0;
  String _crossfadeResolvedKey = '';
  DateTime _lastCrossfadeResolveAttempt =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether mpv rejected an audio filter this session (logged once).
  bool _filterErrorLogged = false;

  /// Session fault counter: steps down to gapless if the two-deck mixer
  /// keeps needing repairs on this machine.
  final MixFaultBudget _mixFaults = MixFaultBudget();
  Timer? _mixWatchdog;
  DateTime? _mixStartedAt;

  /// Repairs seen on the previous watchdog pass. A repair is applied only
  /// when it shows up twice in a row, so an in-flight change (a speed tap,
  /// a volume drag) is never "fixed" and never counted as a fault.
  Set<MixRepair> _pendingRepairs = {};

  /// Where an error-retry of the same track should resume, so a
  /// transient stream failure does not restart the song from 0:00.
  Duration? _resumeAt;
  String _resumeKey = '';

  /// Crash-surviving breadcrumb (`<temp>/neowave/mpv-ops.log`).
  ///
  /// Written synchronously with flush BEFORE each native op, so the
  /// last line names the call that killed the process. Never logs
  /// URLs, cookies, or headers — op names and stream shapes only.
  ///
  /// File-only by design (a release build has no stdout). Mixer lines are
  /// additionally mirrored to the debug console, because "why did the
  /// crossfade not run" is only answerable from the plan/start/fault trail.
  void _crumb(String line) {
    TraceCrumb.write(line);
    if (kDebugMode && line.startsWith('mix')) {
      debugPrint('[mix] $line');
    }
  }

  /// Per-stage timing breadcrumb. Shape/timing only — never URLs,
  /// headers, or tokens. Correlate stages by `key`.
  ///
  /// Recorded in release too (the session log is what a user can export
  /// when the app is slow on *their* machine — these are the numbers that
  /// split a cold open into resolve/assembly/render); the console copy
  /// stays debug-only so a release build stays quiet on stdout.
  void _logTiming(String line) {
    if (kDebugMode) debugPrint('NeoWave-Timing $line');
    TraceCrumb.write('timing $line');
  }

  Timer? _trimTimer;

  /// Every track change frees multi-MB libmpv buffers (demuxer cache, back
  /// buffer, decoder pools) that the native heap keeps resident, so the
  /// working set ratchets up a few hundred MB over a handful of songs.
  /// Hand the idle pages back once the new track is flowing and prefetch
  /// has settled. Debounced: rapid skipping trims once, after the last skip.
  void _scheduleMemoryTrim() {
    _trimTimer?.cancel();
    _trimTimer = Timer(const Duration(seconds: 5), trimProcessMemory);
  }

  /// Fires once per resolve: the first position tick past zero is the
  /// first rendered frame — the closest signal to audible sound.
  /// (NOT `playing=true`: mpv unpauses on loadfile-accept, before the
  /// cache preroll finishes.) Consumed via [_audioClockGeneration] so
  /// later ticks and seeks never re-log. Ticks arriving before open is
  /// issued belong to the outgoing track (mpv keeps playing it until
  /// the stop/open lands) — they must not fire the new clock, which is
  /// exactly the `time_to_audio_ms=7 post_open_ms=-1` ghost.
  void _maybeLogFirstAudio(Duration position) {
    try {
      if (position <= Duration.zero) return;
      if (_audioClockGeneration != _resolveGeneration) return;
      if (_audioOpenDoneAt == null) return;
      final start = _audioClockStart;
      if (start == null || _audioClockKey.isEmpty) return;
      if (state.current?.queueKey != _audioClockKey) return;
      // Audio is flowing, so the current track's own first-byte wait is
      // over and speculative work cannot delay it. (Prefetch started right
      // after `open` ran 1.4-1.8s ahead of this track's first byte.)
      _audioClockGeneration = -1;
      _prefetchNeighbors();
      _scheduleMemoryTrim();
      if (!kDebugMode) return;
      final now = DateTime.now();
      final totalMs = now.difference(start).inMilliseconds;
      final openDone = _audioOpenDoneAt;
      final postOpenMs =
          openDone != null ? now.difference(openDone).inMilliseconds : -1;
      _logTiming('audio key=$_audioClockKey time_to_audio_ms=$totalMs '
          'post_open_ms=$postOpenMs');
    } catch (_) {}
  }

  PlaybackService(
    this._tube,
    this._scrobbler,
    this._downloads,
    this._prefs,
    this._sessions, [
    OfficialArtworkService? artworkService,
  ])  : _artworkService = artworkService ?? OfficialArtworkService(),
        super(const PlayerSnapshot());

  /// Tests run the real decks on mpv's `null` output (real-time clock, no
  /// sound card). Never set in the app.
  @visibleForTesting
  static String? debugAudioOutput;

  Future<void> _applyDebugAudioOutput(Player p) async {
    final ao = debugAudioOutput;
    if (ao == null) return;
    try {
      await (p.platform as dynamic).setProperty('ao', ao);
    } catch (_) {}
  }

  /// Crossfade state for tests: faults so far, both decks' mpv volume.
  @visibleForTesting
  ({int faults, double primaryVolume, double? standbyVolume, bool mixing})
      get debugMixState => (
            faults: _mixFaults.faults,
            primaryVolume: _player?.state.volume ?? -1,
            standbyVolume: _standbyPlayer?.state.volume,
            mixing: _crossfading,
          );

  Future<void> ensurePlayer() async {
    if (_player != null) return;
    // One persistent audio-only libmpv instance with on-disk demuxer cache
    // + gapless. media_kit already defaults to vo=null (audio-only) + the
    // buffer below; we set the rest best-effort via mpv properties. No
    // Rust/C++ involved.
    //
    // ensureInitialized() dlopens libmpv (multi-MB .so). It is called here
    // rather than from main() so the dlopen is off the first-frame path —
    // nothing before the first play needs media_kit. Idempotent, and the
    // only other Player() site (the motion-art session) calls it too.
    MediaKit.ensureInitialized();
    // 16MiB demuxer buffer: a high-bitrate local file peaks ~9Mbps, so this
    // still holds ~14s of the heaviest stream while halving the
    // 32MiB RSS cost (was the single biggest native allocation).
    _player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        title: 'NeoWave',
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    final created = _player!;
    await _applyDebugAudioOutput(created);
    try {
      final platform = created.platform;
      if (platform != null) {
        final dyn = platform as dynamic;
        try {
          await dyn.setProperty('gapless-audio', 'yes');
        } catch (_) {}
        try {
          await dyn.setProperty('cache', 'yes');
        } catch (_) {}
        try {
          await dyn.setProperty('cache-on-disk', 'yes');
        } catch (_) {}
        try {
          // mpv's default on-disk location fails to create here
          // (`Failed to create file cache` on every open), so pin an
          // explicit dir the app creates itself.
          final cacheDir = mpvCacheDirPath();
          await ensureDirExists(cacheDir);
          await dyn.setProperty('cache-dir', cacheDir);
        } catch (_) {}
        try {
          await dyn.setProperty(
              'demuxer-max-back-bytes', '${4 * 1024 * 1024}');
        } catch (_) {}
        try {
          await dyn.setProperty(
              'demuxer-max-bytes', '${16 * 1024 * 1024}');
        } catch (_) {}
        try {
          await dyn.setProperty('vid', 'no');
        } catch (_) {}
        try {
          // Stall tolerance for slow stream starts (loopback assembly
          // waits on CDN first bytes; mpv otherwise aborts the open
          // after ~5s and forces a wasteful retry cycle). Applies to
          // YouTube too — strictly more patient, never less.
          await dyn.setProperty('stream-lavf-o', 'timeout=15000000');
        } catch (_) {}
        if (_currentAudioFilter.isNotEmpty) {
          try {
            await dyn.setProperty('af', _currentAudioFilter);
          } catch (_) {}
        }
      }
    } catch (_) {}
    // Crash-surviving trail: mpv logs to disk continuously and Dart
    // appends one line per native op — both outlive a segfault,
    // unlike stdout. All best-effort; never blocks startup.
    try {
      final trailDir = Directory(TraceCrumb.directory);
      trailDir.createSync(recursive: true);
      // Fresh timeline per session (also names the run in crash logs).
      TraceCrumb.reset(
          '--- player created ${DateTime.now().toIso8601String()} ---');
      try {
        final dyn = created.platform as dynamic;
        await dyn.setProperty('log-file',
            '${trailDir.path}${Platform.pathSeparator}mpv.log');
      } catch (_) {}
    } catch (_) {}
    final p = _player!;
    _bindPlayerStreams(p);
    _startMixWatchdog();
    await restoreSession();
    _rebuildProcessingFilter();
    await _applyLoudness(album: state.current?.album ?? '');
    await _applyRate();
  }

  void _bindPlayerStreams(Player p) {
    _subs.addAll([
      p.stream.playing.listen((v) {
        runGuarded('player.playing', () {
          state = state.copyWith(isPlaying: v);
          _onPlayingChanged(v);
        });
      }),
      p.stream.buffering.listen((v) {
        runGuarded('player.buffering', () {
          if (state.error != null) return;
          state = state.copyWith(isBuffering: _resolving || v);
        });
      }),
      p.stream.position.listen((v) {
        runGuarded('player.position', () {
          _maybeLogFirstAudio(v);
          if (_resolving || state.error != null) return;
          if (state.position == v) return;
          final now = DateTime.now();
          if (now.difference(_lastPositionEmit).inMilliseconds < 100) {
            return;
          }
          _lastPositionEmit = now;
          // Gated to 10Hz: identical scrobble accuracy (wall-clock delta),
          // prefetch is once-per-track. Saves 60Hz DateTime+prefs wakes.
          _tickScrobble(v);
          _maybePrefetchFromPosition(v);
          _updateCrossfadeSchedule(v);
          state = state.copyWith(position: v);
        });
      }),
      p.stream.buffer.listen((v) {
        runGuarded('player.buffer', () {
          if (_resolving || state.error != null) return;
          if (state.buffered == v) return;
          final now = DateTime.now();
          // Always land the completed value so the buffered bar can never
          // stick one gate behind at 100%; intermediate chunks stay 10Hz.
          final complete =
              state.duration > Duration.zero && v >= state.duration;
          if (!complete &&
              now.difference(_lastBufferedEmit).inMilliseconds < 100) {
            return;
          }
          _lastBufferedEmit = now;
          state = state.copyWith(buffered: v);
        });
      }),
      p.stream.duration.listen((v) {
        runGuarded('player.duration', () {
          if (_resolving || state.error != null) return;
          state = state.copyWith(duration: v);
          // Keep scrobble duration in sync with the track that owns the
          // current window — not the next track that has already been
          // written to state during resolve.
          if (_scrobbleTrack != null &&
              _scrobbleTrack!.queueKey == state.current?.queueKey) {
            _scrobbleDurationSec = v.inSeconds;
          }
        });
      }),
      p.stream.volume.listen((v) {
        runGuarded('player.volume', () {
          // Deliberately NOT copied into state.volume. Every volume change
          // the listener makes goes through setVolume(), so state.volume is
          // the single source of truth; mpv's value also moves with mix
          // fades and DAC volume locks, and copying it back once left the
          // app at ~0% after a mix (the next mix then faded to silence).
          // The watchdog puts the deck back if the two ever disagree.
        });
      }),
      p.stream.completed.listen((done) {
        runGuarded('player.completed', () {
          if (done) _onTrackCompleted();
        });
      }),
      p.stream.log.listen((PlayerLog l) {
        runGuarded('player.log', () {
          if (kDebugMode) {
            _mpvLogTail.add(l);
            if (_mpvLogTail.length > _mpvLogTailMax) {
              _mpvLogTail.removeRange(
                  0, _mpvLogTail.length - _mpvLogTailMax);
            }
          }
        });
      }),
      p.stream.error.listen((e) {
        runGuarded('player.error-event', () {
          // A rejected audio filter is not a broken stream: the audio
          // keeps playing. Treating it as one restarted the song, then
          // fell back to YouTube, then marked it unavailable and skipped.
          if (isFilterGraphError(e)) {
            _onFilterGraphError(e);
            return;
          }
          if (kDebugMode) {
            debugPrint('NeoWave-Player: mpv error: $e');
            _dumpMpvLog('p.stream.error');
          }
          unawaited(runGuardedAsync(
              'player.error', () => _onPlayerError()));
        });
      }),
    ]);
  }

  void _rebindPlayerStreams() {
    for (final s in _subs) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    final p = _player;
    if (p != null) {
      _bindPlayerStreams(p);
    }
  }

  // -- Crossfade & Standby hand-off engine ---------------------------------

  Future<void> _ensureStandbyPlayer() async {
    if (_standbyPlayer != null) return;
    MediaKit.ensureInitialized();
    final sb = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        title: 'NeoWave Standby',
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    _standbyPlayer = sb;
    await _applyDebugAudioOutput(sb);
    try {
      final platform = sb.platform as dynamic;
      if (platform != null) {
        try {
          await platform.setProperty('gapless-audio', 'yes');
        } catch (_) {}
        try {
          await platform.setProperty('cache', 'yes');
        } catch (_) {}
        try {
          await platform.setProperty('cache-on-disk', 'yes');
        } catch (_) {}
        final cacheDir = mpvCacheDirPath();
        await ensureDirExists(cacheDir);
        try {
          await platform.setProperty('cache-dir', cacheDir);
        } catch (_) {}
        try {
          await platform.setProperty(
              'demuxer-max-bytes', '${16 * 1024 * 1024}');
        } catch (_) {}
        try {
          await platform.setProperty('vid', 'no');
        } catch (_) {}
        try {
          await platform.setProperty('stream-lavf-o', 'timeout=15000000');
        } catch (_) {}
        if (_currentAudioDevice.isNotEmpty && _currentAudioDevice != 'auto') {
          try {
            await sb.setAudioDevice(AudioDevice(_currentAudioDevice, ''));
          } catch (_) {}
        }
        if (_currentAudioFilter.isNotEmpty) {
          try {
            await platform.setProperty('af', _currentAudioFilter);
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _applyLoudness(album: _standbyTrack?.album ?? '');
    final ready = _standbyPlayer;
    if (ready != null) await _applyRateTo(ready);
  }

  void cancelCrossfade() {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    final restoreChain = _crossfading || _standbyArmed;
    if (_crossfading || _standbyArmed) {
      try {
        _standbyPlayer?.stop();
        _standbyPlayer?.setVolume(0);
      } catch (_) {}
      try {
        _player?.setVolume(_fullDeckVolume);
      } catch (_) {}
    }
    _mixStartedAt = null;
    _crossfading = false;
    _standbyArmed = false;
    _standbyReady = false;
    _standbyTrack = null;
    _standbyStream = null;
    _standbyIndex = -1;
    if (restoreChain) {
      unawaited(_applyRate());
    }
  }

  /// Reloads loudness, and the crossfade setting.
  Future<void> applyAudioPrefs() async {
    _rebuildProcessingFilter();
    await _applyLoudness(album: state.current?.album ?? '');
    await _applyRate();
    refreshOverlapPrefs();
  }

  void refreshOverlapPrefs() {
    if (!_overlapEnabled) {
      cancelCrossfade();
    }
  }

  void _updateCrossfadeSchedule(Duration position) {
    // Crossfade (3–12s) uses the standby deck.
    if (!_overlapEnabled) {
      if (_standbyArmed || _crossfading) cancelCrossfade();
      return;
    }
    if (state.repeatMode == RepeatMode.one) {
      if (_standbyArmed || _crossfading) cancelCrossfade();
      return;
    }
    if (!state.isPlaying || _resolving || state.error != null) return;
    // Once the overlap runs, the timer owns it; re-planning mid-mix (the
    // incoming duration just became known) must not disturb it.
    if (_crossfading) return;
    final duration = state.duration;
    if (duration.inSeconds < 10) return;

    final nextIndex = _nextIndex();
    if (nextIndex == null || !_queueIndexValid(nextIndex)) {
      if (_standbyArmed) cancelCrossfade();
      return;
    }
    final nextTrack = state.queue[nextIndex];
    if (_standbyArmed && _standbyTrack?.queueKey != nextTrack.queueKey) {
      cancelCrossfade();
    }

    final fadeDuration = _overlapLength();
    if (duration < fadeDuration + const Duration(seconds: 8)) {
      if (_standbyArmed) cancelCrossfade();
      return;
    }
    final remaining = duration - position;

    // 1. Pre-resolve the next track before the overlap window.
    final resolveLead = fadeDuration + const Duration(seconds: 12);
    final lead = resolveLead < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : resolveLead;
    if (remaining <= lead && remaining > Duration.zero) {
      _maybeEarlyResolveNextTrack(nextTrack, nextIndex);
    }

    // 2. Load the standby deck well before the overlap window.
    if (remaining <= fadeDuration + _armLead &&
        !_standbyArmed &&
        _mixGaveUpFor != nextTrack.queueKey) {
      _armStandbyForNext(nextTrack, nextIndex);
    }

    // 3. Start the overlap when position enters the window — and only on a
    // deck that is actually ready.
    if (remaining <= fadeDuration &&
        _standbyArmed &&
        _standbyReady &&
        _standbyPlayer != null) {
      _startCrossfade(fadeDuration);
    }

    // 4. Deck still not ready with the window nearly gone: give up on the
    // overlap for this track and let the normal track change happen,
    // instead of firing a half-loaded deck.
    if (_standbyArmed &&
        !_standbyReady &&
        remaining <= fadeDuration - const Duration(seconds: 3)) {
      _mixGaveUpFor = nextTrack.queueKey;
      _crumb('mix gave up key=${nextTrack.queueKey} (deck not ready)');
      cancelCrossfade();
    }
  }

  void _maybeEarlyResolveNextTrack(PlayableTrack nextTrack, int nextIndex) {
    final cacheKey = nextTrack.queueKey;
    if (_playCache.get(cacheKey) != null) return;
    if (_resolveInflight.containsKey(cacheKey)) return;
    final now = DateTime.now();
    if (nextTrack.queueKey == _crossfadeResolvedKey &&
        now.difference(_lastCrossfadeResolveAttempt).inSeconds < 10) {
      return;
    }
    _crossfadeResolvedKey = nextTrack.queueKey;
    _lastCrossfadeResolveAttempt = now;
    unawaited(_resolveRemote(nextTrack).then((stream) {
      if (stream != null) {
        final currentNext = _nextIndex();
        if (currentNext == null || !_queueIndexValid(currentNext)) return;
        if (state.queue[currentNext].queueKey != nextTrack.queueKey) return;
        if (state.repeatMode == RepeatMode.one) return;

        final pos = state.position;
        final dur = state.duration;
        final rem = dur - pos;
        final fade = _currentOverlap();
        if (fade > Duration.zero &&
            rem <= fade + _armLead &&
            !_crossfading &&
            !_standbyArmed &&
            _mixGaveUpFor != nextTrack.queueKey &&
            state.isPlaying) {
          _armStandbyForNext(nextTrack, currentNext);
        }
      }
    }, onError: (_) {}));
  }

  Future<void> _armStandbyForNext(PlayableTrack nextTrack, int nextIndex) async {
    if (_standbyArmed || _crossfading) return;
    if (state.repeatMode == RepeatMode.one) return;

    final cacheKey = nextTrack.queueKey;
    final stream = _localStream(nextTrack) ?? _playCache.get(cacheKey);
    if (stream == null) {
      // Stream resolution is currently in-flight; will arm when finished
      return;
    }
    _standbyArmed = true;
    _standbyReady = false;
    _standbyTrack = nextTrack;
    _standbyIndex = nextIndex;
    _standbyStream = stream;

    await _ensureStandbyPlayer();
    final sb = _standbyPlayer;
    if (sb == null) {
      _standbyArmed = false;
      _standbyReady = false;
      _standbyTrack = null;
      _standbyStream = null;
      _standbyIndex = -1;
      return;
    }
    try {
      await sb.setVolume(0);
      var playUrl = stream.url;
      if (!playUrl.startsWith('http') && !playUrl.startsWith('file:')) {
        try {
          playUrl = Uri.file(playUrl).toString();
        } catch (_) {}
      }
      await _serializedMpv(() async {
        await _applyLoudnessTo(sb, album: nextTrack.album);
        await sb.open(
          Media(playUrl, httpHeaders: stream.requestHeaders),
          play: false,
        );
      });
      await _applyLoudnessTo(sb, album: nextTrack.album);
      await _applyRateTo(sb);
      // Safety checks: cancel if playback state or track shifted during open
      if (!_standbyArmed ||
          _standbyTrack?.queueKey != nextTrack.queueKey ||
          !state.isPlaying) {
        try {
          await sb.stop();
        } catch (_) {}
        _standbyArmed = false;
        _standbyReady = false;
        _standbyTrack = null;
        _standbyStream = null;
        _standbyIndex = -1;
        return;
      }
      // Wait until the deck has really loaded the stream (duration known),
      // so the overlap starts on audible audio, not on a deck still opening.
      final waitStart = DateTime.now();
      while (sb.state.duration == Duration.zero &&
          DateTime.now().difference(waitStart) <
              const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_standbyArmed ||
            _standbyTrack?.queueKey != nextTrack.queueKey) {
          return;
        }
      }
      if (sb.state.duration == Duration.zero) return; // never became ready
      // Opened, filtered and silent at 0: safe to fade in.
      _standbyReady = true;
    } catch (_) {
      _standbyArmed = false;
      _standbyReady = false;
      _standbyTrack = null;
      _standbyStream = null;
      _standbyIndex = -1;
    }
  }

  /// Runs one mixer timer tick; an exception ends the mix cleanly instead
  /// of leaving the decks half-faded with the timer still firing.
  void _guardedTick(Timer timer, String what, void Function() body) {
    try {
      body();
    } catch (e) {
      timer.cancel();
      _mixFault('$what tick threw ${e.runtimeType}');
      _abortMixSafely();
    }
  }

  /// Full level for a deck: the listener's volume.
  double get _fullDeckVolume => state.volume.clamp(0.0, 1.0) * 100;

  /// mpv speed the primary deck should have outside a mix.
  double get _expectedDeckRate {
    return state.speed <= 0 ? 1.0 : state.speed;
  }

  void _mixFault(String why) {
    _crumb('mix fault #${_mixFaults.faults + 1}: $why');
    final change = _mixFaults.record();
    if (change != null) _crumb('mix safety: $change');
  }

  /// Last-resort reset after an unexpected error in mixer code: whatever
  /// state the flags were in, end with one audible deck at full level.
  void _abortMixSafely() {
    try {
      cancelCrossfade();
    } catch (_) {}
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfading = false;
    _standbyArmed = false;
    _standbyReady = false;
    _mixStartedAt = null;
    try {
      _standbyPlayer?.setVolume(0);
      _player?.setVolume(_fullDeckVolume);
    } catch (_) {}
  }

  /// Once a second: compare the decks with what they should be and fix
  /// any drift (see deck_guard.dart). Runs whether or not a crossfade is
  /// scheduled, so a leftover from any mix path gets cleaned up.
  void _startMixWatchdog() {
    _mixWatchdog?.cancel();
    _mixWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      try {
        _runMixWatchdog();
      } catch (_) {}
    });
  }

  void _runMixWatchdog() {
    final p = _player;
    if (p == null) return;
    final sb = _standbyPlayer;
    final started = _mixStartedAt;
    final repairs = checkMix(MixGuardInput(
      mixing: _crossfading,
      armed: _standbyArmed,
      ramping: false,
      fullVolume: _fullDeckVolume,
      expectedRate: _expectedDeckRate,
      primary: DeckReading(
          volume: p.state.volume, playing: p.state.playing, rate: p.state.rate),
      standby: sb == null
          ? null
          : DeckReading(
              volume: sb.state.volume,
              playing: sb.state.playing,
              rate: sb.state.rate),
      mixAge:
          started == null ? Duration.zero : DateTime.now().difference(started),
      resolving: _resolving,
    ));
    final confirmed = repairs
        .where((r) =>
            r == MixRepair.abortStuckMix || _pendingRepairs.contains(r))
        .toList();
    _pendingRepairs = repairs.toSet();
    for (final r in confirmed) {
      _pendingRepairs.remove(r);
      _mixFault('watchdog ${r.name}');
      switch (r) {
        case MixRepair.abortStuckMix:
          if (_standbyReady && _standbyTrack != null) {
            _completeCrossfade();
          } else {
            _abortMixSafely();
          }
        case MixRepair.silenceStandby:
          try {
            sb?.setVolume(0);
            if (!_standbyArmed) sb?.stop();
          } catch (_) {}
        case MixRepair.restorePrimaryVolume:
          try {
            p.setVolume(_fullDeckVolume);
          } catch (_) {}
        case MixRepair.restoreRate:
          unawaited(_applyRateTo(p));
      }
    }
  }

  /// mpv rejected an audio filter (the EQ).
  /// That is NOT a broken stream: it leaves the track with NO audio (mpv
  /// ends the file). Drop processing for the session and reopen the song
  /// where it was, instead of failing every track.
  void _onFilterGraphError(String text) {
    if (!_filterErrorLogged) {
      _filterErrorLogged = true;
      _crumb('filter rejected (not a stream error): '
          '${text.length > 120 ? text.substring(0, 120) : text}');
    }
    // Mid-overlap the decks are being driven by the mix timer; tearing the
    // stream down there would fight it. Leave it for the next quiet error.
    if (_crossfading || _standbyArmed) return;
    if (_currentAudioFilter.isEmpty || _processingDisabled) return;
    _processingDisabled = true;
    _crumb('processing filter rejected -> disabled, reopening');
    _rebuildProcessingFilter();
    final idx = state.currentIndex;
    final pos = state.position;
    final key = state.current?.queueKey;
    unawaited(runGuardedAsync('filter-recover', () async {
      try {
        await _applyRate();
      } catch (_) {}
      if (key != null && pos > const Duration(seconds: 3)) {
        _resumeKey = key;
        _resumeAt = pos;
      }
      await _resolveAndOpen(idx, forceRefresh: false);
    }));
  }

  void _startCrossfade(Duration fadeDuration) {
    if (_crossfading || !_standbyArmed || _standbyPlayer == null) return;
    _crossfading = true;
    _crossfadeDuration = fadeDuration;
    _crossfadeStartTime = DateTime.now();
    _mixStartedAt = DateTime.now();
    _crossfadeTargetVolume = _fullDeckVolume / 100;
    _crumb('crossfade start key=${_standbyTrack?.queueKey} '
        'overlap=${fadeDuration.inSeconds}s');

    try {
      unawaited(_standbyPlayer!.play());
    } catch (_) {
      cancelCrossfade();
      return;
    }

    _crossfadeTimer?.cancel();
    _crossfadeTimer = Timer.periodic(const Duration(milliseconds: 25),
        (timer) => _guardedTick(timer, 'crossfade', () {
      if (!_crossfading) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(_crossfadeStartTime!);
      final progress = (elapsed.inMilliseconds /
              _crossfadeDuration!.inMilliseconds)
          .clamp(0.0, 1.0);
      final masterVol100 = (_crossfadeTargetVolume * 100).clamp(0.0, 100.0);

      // Smoothed equal-power curve: level loudness, gentle at both ends.
      final outGain = math.cos(progress * math.pi / 2);
      final inGain = math.sin(progress * math.pi / 2);
      final outVol = outGain * masterVol100;
      final inVol = inGain * masterVol100;

      try {
        _player?.setVolume(outVol.clamp(0.0, 100.0));
        _standbyPlayer?.setVolume(inVol.clamp(0.0, 100.0));
      } catch (_) {}

      if (progress >= 1.0) {
        timer.cancel();
        _completeCrossfade();
      }
    }));
  }

  void _completeCrossfade() {
    try {
      _completeCrossfadeUnsafe();
    } catch (e) {
      _mixFault('hand-off threw ${e.runtimeType}');
      _abortMixSafely();
    }
  }

  void _completeCrossfadeUnsafe() {
    if (!_crossfading) return;
    _mixStartedAt = null;
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;

    final incomingTrack = _standbyTrack;
    final incomingIndex = _standbyIndex;
    final incomingStream = _standbyStream;
    final sb = _standbyPlayer;

    if (incomingTrack == null || sb == null) {
      cancelCrossfade();
      return;
    }

    _flushScrobble(completed: true);

    final oldPrimary = _player;
    try {
      oldPrimary?.stop();
      oldPrimary?.setVolume(0);
    } catch (_) {}

    try {
      sb.setVolume(_fullDeckVolume);
      unawaited(_applyRateTo(sb));
      unawaited(_applyLoudnessTo(sb, album: incomingTrack.album));
    } catch (_) {}
    _player = sb;
    _standbyPlayer = oldPrimary;

    _rebindPlayerStreams();

    final trackDur = sb.state.duration;
    // The incoming deck has already been playing for the whole overlap, so
    // it keeps ITS real position — resetting the clock to 0 here made the
    // new track look (and scrobble/lyric-sync) as if it restarted.
    final livePos = sb.state.position;
    // A deck that somehow stayed paused must not hand over silence.
    if (!sb.state.playing) {
      try {
        unawaited(sb.play());
      } catch (_) {}
    }

    _activeQueueKey = incomingTrack.queueKey;
    _audioClockKey = incomingTrack.queueKey;
    _audioClockStart = DateTime.now();
    _audioOpenDoneAt = DateTime.now();

    state = state.copyWith(
      currentIndex: incomingIndex,
      current: incomingTrack,
      stream: incomingStream,
      bitrateKbps: incomingStream?.bitrateKbps,
      isPlaying: true,
      isBuffering: false,
      position: livePos > Duration.zero ? livePos : Duration.zero,
      duration: trackDur,
      clearError: true,
    );

    _beginScrobbleWindow(incomingTrack);

    _crossfading = false;
    _standbyArmed = false;
    _standbyReady = false;
    _standbyTrack = null;
    _standbyStream = null;
    _standbyIndex = -1;

    _prefetchNeighbors();
    _maybeRefillRadio();
    _schedulePersist();
  }

  /// Ordered teardown for app quit: awaits the queued mpv stop/dispose
  /// so no texture callbacks fire after the Flutter view is destroyed
  /// (release-only `flutter_windows+1e220` crash on close).
  Future<void> disposePlayer() async {
    _mixWatchdog?.cancel();
    _mixWatchdog = null;
    // Flush any past-threshold window before tearing down (manual pause/
    // app close would otherwise leave it only as “Scrobbling now”).
    cancelCrossfade();
    _flushScrobble(completed: false);
    _resolveGeneration++;
    _resolving = false;
    _resolvingIndex = -1;
    _activeQueueKey = '';
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _sleepTimer?.cancel();
    _persistThrottle?.cancel();
    final standby = _standbyPlayer;
    _standbyPlayer = null;
    if (standby != null) {
      try {
        await standby.stop();
        await standby.dispose();
      } catch (_) {}
    }
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await _serializedMpv(() async {
          try {
            await player.stop();
          } catch (_) {}
          try {
            await player.dispose();
          } catch (_) {}
        }).timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
    }
  }

  // -- queue API ---------------------------------------------------------------

  Future<void> play(
    PlayableTrack track, {
    String sourceLabel = '',
    bool startRadio = false,
  }) async {
    await playQueue([track], 0,
        sourceLabel: sourceLabel, endlessRadio: startRadio);
  }

  Future<void> playQueue(
    List<PlayableTrack> tracks,
    int startIndex, {
    String sourceLabel = '',
    bool startShuffled = false,
    bool endlessRadio = false,
  }) async {
    cancelCrossfade();
    await ensurePlayer();
    if (tracks.isEmpty) return;
    var index = startIndex.clamp(0, tracks.length - 1);
    var queue = List<PlayableTrack>.of(tracks);
    var shuffle = state.shuffleEnabled;
    if (startShuffled) {
      shuffle = true;
      queue = List.of(tracks)..shuffle();
      // tracks[index], not tracks[startIndex]: index is the clamped
      // value, so an out-of-range start cannot throw a RangeError.
      final start = tracks[index];
      index = queue.indexWhere((t) => t.mediaId == start.mediaId);
      if (index < 0) index = 0;
    }
    _endlessRadio = endlessRadio;
    _radioSeeds.clear();
    _unavailable.clear();
    _prefetchSeedKey = '';
    _rebuildShuffleOrder(queue.length, index);
    state = state.copyWith(
      queue: queue,
      currentIndex: index,
      current: queue[index],
      sourceLabel: sourceLabel,
      shuffleEnabled: shuffle,
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(index);
  }

  Future<void> playNext(PlayableTrack track) async {
    final queue = List<PlayableTrack>.of(state.queue);
    final at =
        state.currentIndex >= 0 ? state.currentIndex + 1 : queue.length;
    queue.insert(at, track);
    _rebuildShuffleOrder(queue.length, state.currentIndex);
    state = state.copyWith(queue: queue);
    _schedulePersist();
    _prefetchNeighbors();
  }

  Future<void> addToQueue(PlayableTrack track) async {
    final queue = List<PlayableTrack>.of(state.queue)..add(track);
    _rebuildShuffleOrder(queue.length, state.currentIndex);
    state = state.copyWith(queue: queue);
    _schedulePersist();
    _prefetchNeighbors();
  }

  Future<void> removeAt(int index) async {
    final queue = List<PlayableTrack>.of(state.queue);
    if (index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    var currentIndex = state.currentIndex;
    if (index < currentIndex) {
      currentIndex--;
    } else if (index == currentIndex) {
      if (queue.isEmpty) {
        await stopAndClear();
        return;
      }
      currentIndex = currentIndex.clamp(0, queue.length - 1);
      state = state.copyWith(
          queue: queue, currentIndex: currentIndex, current: queue[currentIndex]);
      await _resolveAndOpen(currentIndex);
      return;
    }
    _rebuildShuffleOrder(queue.length, currentIndex);
    state = state.copyWith(queue: queue, currentIndex: currentIndex);
    _schedulePersist();
  }

  Future<void> clearUpcoming() async {
    if (state.currentIndex < 0) return;
    final queue = state.queue.sublist(0, state.currentIndex + 1);
    state = state.copyWith(queue: queue);
    _schedulePersist();
  }

  /// Reorder queue via drag: updates actual playback queue and keeps
  /// current index pointing at the same track. No re-resolve.
  Future<void> moveInQueue(int oldIndex, int newIndex) async {
    final queue = List<PlayableTrack>.of(state.queue);
    if (oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex > queue.length) {
      return;
    }
    if (oldIndex == newIndex ||
        oldIndex == newIndex - 1) {
      return;
    }
    final current = state.current;
    final item = queue.removeAt(oldIndex);
    var adjusted = newIndex;
    if (newIndex > oldIndex) adjusted -= 1;
    queue.insert(adjusted.clamp(0, queue.length), item);
    var currentIndex = current == null
        ? state.currentIndex
        : queue.indexWhere((t) => t.queueKey == current.queueKey);
    if (currentIndex < 0) currentIndex = state.currentIndex.clamp(0, queue.length - 1);
    _rebuildShuffleOrder(queue.length, currentIndex);
    state = state.copyWith(
      queue: queue,
      currentIndex: currentIndex,
      current: queue.isEmpty ? null : queue[currentIndex.clamp(0, queue.length - 1)],
    );
    _schedulePersist();
  }

  // -- transport ---------------------------------------------------------------

  DateTime _lastToggleTime = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> toggle() async {
    final now = DateTime.now();
    if (now.difference(_lastToggleTime).inMilliseconds < 150) return;
    _lastToggleTime = now;
    await ensurePlayer();
    if (state.error != null) {
      await retry();
      return;
    }
    // Session restore loads queue/current but no Media in mpv — playOrPause
    // on an empty player is a no-op (user hits play and nothing happens;
    // next/prev/new track work because they re-resolve). Detect that case
    // and open the restored track instead.
    if (state.current != null && state.stream == null) {
      final resumeAt = state.position;
      await _resolveAndOpen(state.currentIndex);
      if (resumeAt > Duration.zero) {
        // Best-effort: resume where the session left off.
        await seek(resumeAt);
      }
      return;
    }
    // Pausing mid-mix must silence the incoming deck too, not just the
    // outgoing one; the mix re-plans from where playback resumes.
    if (state.isPlaying && (_crossfading || _standbyArmed)) {
      cancelCrossfade();
    }
    try {
      await _player?.playOrPause();
    } catch (_) {}
  }

  Future<void> playResume() async {
    await ensurePlayer();
    if (state.current != null && state.stream == null) {
      final resumeAt = state.position;
      await _resolveAndOpen(state.currentIndex);
      if (resumeAt > Duration.zero) {
        await seek(resumeAt);
      }
      return;
    }
    try {
      await _player?.play();
    } catch (_) {}
  }

  Future<void> pause() async {
    cancelCrossfade();
    try {
      await _player?.pause();
    } catch (_) {}
    _schedulePersist();
  }

  Future<void> seek(Duration position) async {
    cancelCrossfade();
    await _player?.seek(position);
    state = state.copyWith(position: position);
  }

  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    if (_crossfading) {
      _crossfadeTargetVolume = _fullDeckVolume / 100;
      return;
    }
    await _player?.setVolume(_fullDeckVolume);
  }

  /// Output devices as mpv lists them, and the live changes to that list.
  List<AudioDevice> get audioDevices => _player?.state.audioDevices ?? const [];
  Stream<List<AudioDevice>> get audioDeviceChanges =>
      _player?.stream.audioDevices ?? const Stream.empty();

  /// Routes mpv output to [mpvDevice] (`'auto'` = system default). The
  /// remembered device also applies to standby decks opened for a crossfade.
  Future<void> setOutputDevice(String mpvDevice) async {
    await ensurePlayer();
    _currentAudioDevice = mpvDevice;
    final player = _player;
    if (player == null) return;
    try {
      if (mpvDevice.isEmpty || mpvDevice == 'auto') {
        await player.setAudioDevice(AudioDevice.auto());
      } else {
        await player.setAudioDevice(AudioDevice(mpvDevice, ''));
      }
    } catch (_) {}
  }

  /// Sets or clears the 10-band equalizer graph in libmpv.
  ///
  /// Loudness stays on mpv's replaygain stage so it does not replace this
  /// string.
  Future<void> setAudioFilter(String af) async {
    _eqFilter = af;
    // A rejected graph latches processing off for the session (see the
    // filter-error path). A new graph from the user is a new attempt, so
    // clear the latch — otherwise every dial change after one rejection
    // is silently dropped until the app restarts.
    _processingDisabled = false;
    _rebuildProcessingFilter();
    await _applyRate();
  }

  void _rebuildProcessingFilter() {
    _currentAudioFilter = _processingDisabled ? '' : _eqFilter;
  }

  /// Speed goes through media_kit [Player.setRate] with mpv pitch
  /// correction on; the `af` chain is just the equalizer graph.
  Future<void> _applyRate() async {
    final primary = _player;
    if (primary != null) await _applyRateTo(primary);
    if (_standbyArmed) {
      final sb = _standbyPlayer;
      if (sb != null) await _applyRateTo(sb);
    }
  }

  Future<void> _applyRateTo(Player player) async {
    final rate = state.speed <= 0 ? 1.0 : state.speed;
    final dyn = player.platform;
    if (dyn != null) {
      try {
        await (dyn as dynamic).setProperty('audio-pitch-correction', 'yes');
      } catch (_) {}
    }
    try {
      await player.setRate(rate);
    } catch (_) {}
    if (dyn != null) {
      try {
        await (dyn as dynamic).setProperty('af', _currentAudioFilter);
      } catch (_) {}
    }
  }

  Future<void> _applyLoudness({String album = ''}) async {
    await _applyLoudnessTo(_player, album: album);
    if (_standbyPlayer != null) {
      await _applyLoudnessTo(_standbyPlayer, album: _standbyTrack?.album ?? album);
    }
  }

  /// mpv replaygain stage. Composes with `af` (EQ)
  /// because it is not written into that string. No tag: fixed fallback.
  /// Album mode uses one shared album gain for later untagged tracks in
  /// the same album when libmpv reported the same album tag.
  Future<void> _applyLoudnessTo(Player? player, {String album = ''}) async {
    if (player == null) return;
    final dyn = player.platform;
    if (dyn == null) return;
    final mode = LoudnessMath.normalizeMode(_prefs.loudnessMode);
    try {
      if (mode == 'off') {
        await (dyn as dynamic).setProperty('replaygain', 'no');
        await (dyn as dynamic).setProperty('replaygain-fallback', '0');
        return;
      }
      final fallback = _loudnessFallbackDb(album);
      await (dyn as dynamic).setProperty('replaygain', mode);
      await (dyn as dynamic).setProperty(
          'replaygain-preamp', LoudnessMath.preampDb.toStringAsFixed(1));
      await (dyn as dynamic).setProperty('replaygain-clip', 'yes');
      await (dyn as dynamic).setProperty(
          'replaygain-fallback', fallback.toStringAsFixed(2));
    } catch (_) {}
  }

  double _loudnessFallbackDb(String album) {
    if (_prefs.loudnessMode != 'album') return LoudnessMath.fallbackDb;
    final key = album.trim().toLowerCase();
    if (key.isEmpty) return LoudnessMath.fallbackDb;
    final shared = _albumReplayGainDb[key];
    if (shared == null || !shared.isFinite) return LoudnessMath.fallbackDb;
    return (shared + LoudnessMath.preampDb)
        .clamp(-LoudnessMath.clampDb, LoudnessMath.clampDb)
        .toDouble();
  }

  void _rememberAlbumGain(String album, double? gainDb) {
    if (_prefs.loudnessMode != 'album') return;
    final key = album.trim().toLowerCase();
    if (key.isEmpty || gainDb == null || !gainDb.isFinite) return;
    final prev = _albumReplayGainDb[key];
    if (prev == null) {
      _albumReplayGainDb[key] = gainDb;
      return;
    }
    if (!prev.isFinite) return;
    if (!LoudnessMath.sameAlbumGain(prev, gainDb)) {
      _albumReplayGainDb[key] = double.nan;
    }
  }

  Future<void> _captureAlbumGain(PlayableTrack track) async {
    if (_prefs.loudnessMode == 'off') return;
    final dyn = _player?.platform;
    if (dyn == null) return;
    final gain = await _readAlbumGainProperty(dyn);
    _rememberAlbumGain(track.album, gain);
  }

  Future<double?> _readAlbumGainProperty(dynamic dyn) async {
    const keys = [
      'metadata/REPLAYGAIN_ALBUM_GAIN',
      'metadata/replaygain_album_gain',
    ];
    for (final key in keys) {
      try {
        final raw = await dyn.getProperty(key);
        final parsed = LoudnessMath.parseDb(raw?.toString());
        if (parsed != null) return parsed;
      } catch (_) {}
    }
    try {
      final raw = await dyn.getProperty('metadata');
      final text = raw?.toString() ?? '';
      final match = RegExp(
        'replaygain_album_gain[^0-9\\-]*(-?[0-9]+(?:\\.[0-9]+)?)',
        caseSensitive: false,
      ).firstMatch(text);
      if (match != null) return LoudnessMath.parseDb(match.group(1));
    } catch (_) {}
    return null;
  }

  Future<void> next() async {
    cancelCrossfade();
    final nextIndex = _nextIndex();
    if (nextIndex == null) return;
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(nextIndex);
  }

  Future<void> previous() async {
    cancelCrossfade();
    if (state.position > const Duration(seconds: 5)) {
      await seek(Duration.zero);
      return;
    }
    final prevIndex = _prevIndex();
    if (prevIndex == null) {
      await seek(Duration.zero);
      return;
    }
    // An explicit Previous is a fresh attempt: a track marked unavailable
    // by an earlier failure must not bounce the press straight back to
    // the next track.
    _unavailable.remove(state.queue[prevIndex].queueKey);
    state = state.copyWith(
      currentIndex: prevIndex,
      current: state.queue[prevIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(prevIndex);
  }

  Future<void> seekToQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    cancelCrossfade();
    _unavailable.remove(state.queue[index].queueKey);
    state = state.copyWith(
      currentIndex: index,
      current: state.queue[index],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(index);
  }

  Future<void> toggleShuffle() async {
    cancelCrossfade();
    final enabled = !state.shuffleEnabled;
    _rebuildShuffleOrder(state.queue.length, state.currentIndex);
    state = state.copyWith(shuffleEnabled: enabled);
    _schedulePersist();
  }

  Future<void> cycleRepeat() async {
    cancelCrossfade();
    final next = switch (state.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    state = state.copyWith(repeatMode: next);
    _schedulePersist();
  }

  Future<void> setSpeed(double speed) async {
    // Continuous control is 0.5×–1.5×. 2.0× stays available as a preset.
    final clamped = speed.clamp(0.5, 2.0).toDouble();
    state = state.copyWith(speed: clamped);
    await _applyRate();
    _schedulePersist();
  }

  Future<void> cycleSpeed() async {
    const steps = [0.75, 1.0, 1.25, 1.5, 2.0];
    var idx = steps.indexWhere((s) => s >= state.speed);
    idx = (idx + 1) % steps.length;
    await setSpeed(steps[idx]);
  }

  /// One timer. [duration] null (Off) or the deadline firing both cancel
  /// it and pause. Off while nothing is armed does not pause.
  void setSleepTimer(Duration? duration) {
    final had = _sleepDeadline != null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (duration == null || duration <= Duration.zero) {
      _sleepDeadline = null;
      state = state.copyWith(clearSleep: true);
      if (had) pause();
      return;
    }
    _sleepDeadline = DateTime.now().add(duration);
    final minutes = duration.inMinutes <= 0 ? 1 : duration.inMinutes;
    state = state.copyWith(
      sleepRemaining: duration,
      sleepMinutes: minutes,
    );
    _sleepTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        final remaining = _sleepDeadline?.difference(DateTime.now());
        if (remaining == null || remaining <= Duration.zero) {
          _sleepTimer?.cancel();
          _sleepTimer = null;
          _sleepDeadline = null;
          state = state.copyWith(clearSleep: true);
          pause();
        } else {
          state = state.copyWith(sleepRemaining: remaining);
        }
      },
    );
  }

  Future<void> retry() async {
    if (state.currentIndex < 0) return;
    state = state.copyWith(clearError: true, isBuffering: true);
    _unavailable.remove(state.current!.queueKey);
    _invalidatePlayCache(state.current!);
    await _resolveAndOpen(state.currentIndex, forceRefresh: true);
  }

  Future<void> stopAndClear() async {
    cancelCrossfade();
    _flushScrobble(completed: false);
    _resolveGeneration++;
    _resolving = false;
    _resolvingIndex = -1;
    _activeQueueKey = '';
    _crumb('stop requested (stopAndClear)');
    try {
      await _serializedMpv(() async {
        await _player?.stop();
        await _standbyPlayer?.stop();
      });
    } catch (_) {}
    _lastWasDash = false;
    _endlessRadio = false;
    _sessions.clear();
    _playCache.clear();
    _resolveInflight.clear();
    _prefetchInflight.clear();
    _prefetchSeedKey = '';
    state = const PlayerSnapshot(
      shuffleEnabled: false,
      repeatMode: RepeatMode.off,
      speed: 1.0,
    );
    final reset = _player;
    if (reset != null) unawaited(_applyRateTo(reset));
  }

  // -- resolution ----------------------------------------------------------
  //
  // Local files first, then YouTube.
  // Generation and queue identity reject stale results after track changes.

  Future<void> _resolveAndOpen(int index,
      {bool forceRefresh = false, int attempt = 0}) async {
    if (index < 0 || index >= state.queue.length) return;
    // Prevent duplicate resolver requests for the same index.
    if (_resolving &&
        _resolvingIndex == index &&
        _activeQueueKey == state.queue[index].queueKey &&
        attempt == 0 &&
        !forceRefresh) {
      return;
    }
    if (attempt == 0 && !forceRefresh) {
      _resumeKey = '';
      _resumeAt = null;
    }
    final generation = ++_resolveGeneration;
    _resolving = true;
    _resolvingIndex = index;
    _playbackAttempt = attempt;
    final totalSw = Stopwatch()..start();
    final track = state.queue[index];
    final wantedQueueKey = track.queueKey;
    int resolveMs = 0;
    try {
      _activeQueueKey = wantedQueueKey;
      // Arm the first-audio clock: resolve-start → first playing=true.
      _audioClockStart = DateTime.now();
      _audioClockKey = wantedQueueKey;
      _audioClockGeneration = generation;
      _audioOpenDoneAt = null;
      final cached = !forceRefresh ? _playCache.get(track.queueKey) : null;
      state = state.copyWith(
        isBuffering: true,
        clearError: true,
        stream: cached,
        clearStream: cached == null,
        position: Duration.zero,
        buffered: Duration.zero,
        duration: Duration.zero,
        bitrateKbps: cached?.bitrateKbps ?? 0,
      );
      if (generation != _resolveGeneration) return;
      if (_unavailable.contains(track.queueKey) && attempt == 0) {
        await _skipUnavailable(index);
        return;
      }
      _beginScrobbleWindow(track);
      // Neighbour prefetch deliberately runs after this track is open
      // (bottom of this method / local branch): starting three
      // speculative resolves before the current one subscribed the
      // link, which measured +1s on search/mint and ~2.5s on the
      // current track's first byte.
      final local = _localStream(track);
      if (local != null) {
        _resolving = false;
        final localOpenSw = Stopwatch()..start();
        await _open(track, local, generation, wantedQueueKey);
        localOpenSw.stop();
        totalSw.stop();
        _logTiming('play key=$wantedQueueKey path=local '
            'mpv_open_ms=${localOpenSw.elapsedMilliseconds} '
            'total_ms=${totalSw.elapsedMilliseconds}');
        return;
      }
      if (cached == null) {
        // Cut audio fast, but serialized: a stop racing an in-flight
        // open corrupts the Windows libmpv heap.
        _crumb('stop requested resolve=$index key=$wantedQueueKey');
        // Separates mpv teardown from the resolve chain in the trail:
        // a stop that drags on is not a resolver problem.
        final stopSw = Stopwatch()..start();
        try {
          await _serializedMpv(() async {
            await _player?.stop();
          });
        } catch (_) {}
        stopSw.stop();
        _crumb('stop done key=$wantedQueueKey '
            'ms=${stopSw.elapsedMilliseconds}');
      }
      final resolveSw = Stopwatch()..start();
      final stream =
          cached ?? await _resolveRemote(track, forceRefresh: forceRefresh);
      resolveSw.stop();
      resolveMs = cached != null ? 0 : resolveSw.elapsedMilliseconds;
      // Stale guard: generation + track identity must still match.
      if (generation != _resolveGeneration) return;
      if (index >= state.queue.length ||
          state.queue[index].queueKey != wantedQueueKey) {
        return;
      }
      if (stream == null) {
        // Stale check before triggering retry or skip
        if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;

        _unavailable.add(track.queueKey);
        if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
        await _skipUnavailable(index);
        return;
      }

      final openSw = Stopwatch()..start();
      await _open(track, stream, generation, wantedQueueKey);
      openSw.stop();
      totalSw.stop();

      // Guard: if user clicked next during _open, exit immediately
      if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;

      _logTiming('play key=$wantedQueueKey path=remote '
          'playcache_hit=${cached != null} '
          'resolve_ms=$resolveMs '
          'mpv_open_ms=${openSw.elapsedMilliseconds} '
          'total_ms=${totalSw.elapsedMilliseconds}');

      _maybeRefillRadio();
    } catch (e) {
      // Strictly ignore errors from outdated skip requests
      if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
      state = state.copyWith(
        isPlaying: false,
        isBuffering: false,
        clearStream: true,
        error: 'Could not load this track. Press Play to retry.',
      );
    } finally {
      // Only release the resolving lock if THIS specific generation is still the latest
      if (generation == _resolveGeneration) {
        _resolving = false;
        _resolvingIndex = -1;
      }
    }
  }

  ResolvedStream? _localStream(PlayableTrack track) {
    String? path;
    if (track.playbackUrl.isNotEmpty &&
        File(track.playbackUrl).existsSync()) {
      path = track.playbackUrl;
    } else {
      path = _downloads.localPathFor(track.title, track.artist);
    }
    if (path == null) return null;
    final ext = path.split('.').last.toLowerCase();
    final isFlacOrWav = ext == 'flac' || ext == 'wav';
    return ResolvedStream(
      url: Uri.file(path).toString(),
      mimeType: ext == 'flac'
          ? 'audio/flac'
          : ext == 'mp3'
              ? 'audio/mpeg'
              : 'audio/mp4',
      bitrateKbps: isFlacOrWav ? 1411 : 256,
      audioCodec: isFlacOrWav ? 'FLAC' : ext.toUpperCase(),
      cacheKey: 'local:${track.queueKey}',
    );
  }

  void _invalidatePlayCache(PlayableTrack track) {
    _playCache.invalidate(track.queueKey);
  }

  Future<ResolvedStream?> _resolveRemote(
    PlayableTrack track, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = track.queueKey;
    if (!forceRefresh) {
      final hit = _playCache.get(cacheKey);
      if (hit != null) return hit;
      final pending = _resolveInflight[cacheKey];
      if (pending != null) return pending;
    }
    final future = _resolveRemoteUncached(track, forceRefresh: forceRefresh);
    _resolveInflight[cacheKey] = future;
    try {
      final stream = await future;
      if (stream != null) {
        // Cache every resolved stream. A prefetched YouTube stream is
        // reused when the track is clicked, instead of resolving it
        // again. ResolvedStreamCache drops
        // entries 2 minutes before their signed URL expires, so a stale
        // hit can never reach mpv.
        _playCache.put(cacheKey, stream);
      }
      return stream;
    } finally {
      _resolveInflight.remove(cacheKey);
    }
  }

  Future<ResolvedStream?> _resolveRemoteUncached(
    PlayableTrack track, {
    bool forceRefresh = false,
  }) async {
    final ytSw = Stopwatch()..start();
    final yt = await _resolveYoutube(track, const {},
        forceRefresh: forceRefresh);
    ytSw.stop();
    _logTiming('resolve key=${track.queueKey} path=youtube '
        'youtube_ms=${ytSw.elapsedMilliseconds} hit=${yt != null}');
    return yt;
  }

  Future<ResolvedStream?> _resolveYoutube(
    PlayableTrack track,
    Set<String> excluded, {
    bool forceRefresh = false,
  }) async {
    // Instant playback: a valid videoId goes straight to the resolver
    // (disk/memory cache or one fast InnerTube client). No search,
    // no lyrics/artwork/Last.fm/recommendation gating.
    if (track.videoId.isNotEmpty &&
        !excluded.contains(track.videoId)) {
      try {
        final directSw = Stopwatch()..start();
        final stream = await _tube.resolveAudioStream(track.videoId,
            forceRefresh: forceRefresh,
            preferSmallest: _preferSmallestYoutube);
        directSw.stop();
        _logTiming('youtube key=${track.queueKey} path=direct-videoId '
            'stream_ms=${directSw.elapsedMilliseconds} '
            'hit=${stream != null}');
        if (stream != null) {
          _rememberWatchtime(track.videoId, stream);
          return stream;
        }
      } catch (_) {}
      // Real failure (e.g. 403): drop the cached URL and try one
      // limited re-match below instead of fanning out.
      try {
        _tube.reportPlaybackFailure(track.videoId);
      } catch (_) {}
      excluded = {...excluded, track.videoId};
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      int matchMs = 0;
      try {
        // Best-effort: strict → primary-artist (collab billing like
        // "A; B; C") → title-only. Home feed tracks carry Last.fm
        // billing that fails the strict artist gate on songs that
        // plainly exist on YouTube. Budgets live inside (5s/tier);
        // the outer cap is a safety net only.
        final matchSw = Stopwatch()..start();
        final match = await _tube
            .findBestEffortMatchOrNull(
              track.title,
              track.artist,
              excludedVideoIds: excluded,
            )
            .timeout(const Duration(seconds: 20), onTimeout: () => null);
        matchSw.stop();
        matchMs = matchSw.elapsedMilliseconds;
        final videoId = match?.videoId;
        if (videoId == null || videoId.isEmpty) {
          _logTiming('youtube key=${track.queueKey} attempt=$attempt '
              'match_ms=$matchMs result=no-match');
          return null;
        }
        if (excluded.contains(videoId)) continue;
        // Persist the match so the next play is instant.
        _adoptVideoId(track, videoId, match!);
        final streamSw = Stopwatch()..start();
        final stream = await _tube.resolveAudioStream(videoId,
            forceRefresh: forceRefresh && attempt == 0,
            preferSmallest: _preferSmallestYoutube);
        streamSw.stop();
        _logTiming('youtube key=${track.queueKey} attempt=$attempt '
            'match_ms=$matchMs stream_ms=${streamSw.elapsedMilliseconds} '
            'hit=${stream != null}');
        if (stream != null) {
          _rememberWatchtime(videoId, stream);
          return stream;
        }
        _tube.reportPlaybackFailure(videoId);
        excluded = {...excluded, videoId};
      } catch (_) {}
    }
    return null;
  }

  /// Write a newly matched videoId back into the queue entry so future
  /// plays hit the instant path without another search.
  void _adoptVideoId(
      PlayableTrack track, String videoId, YouTubeMusicTrack match) {
    try {
      final idx = state.queue
          .indexWhere((t) => t.mediaId == track.mediaId);
      if (idx < 0) return;
      final cur = state.queue[idx];
      if (cur.videoId.isNotEmpty) return;
      final updated = cur.copyWith(
        videoId: videoId,
        artworkUrl: OfficialArtworkService.isOfficialArtwork(cur.artworkUrl)
            ? cur.artworkUrl
            : (match.artworkUrl.isNotEmpty ? match.artworkUrl : cur.artworkUrl),
      );
      final queue = List<PlayableTrack>.of(state.queue);
      queue[idx] = updated;
      state = state.copyWith(
        queue: queue,
        current: idx == state.currentIndex ? updated : state.current,
      );
    } catch (_) {}
  }

  /// Warm the queue around the current track: `next`/`prev` stream URLs
  /// plus studio artwork, never opening mpv or injecting a queue item.
  /// `next+1` is only warm-started once the current track is past
  /// halfway ([lookahead]), because a third speculative assembly
  /// competes with the playing track's own segments on the same link.
  /// Work is queued on [_prefetchChain] so neighbours resolve one at a
  /// time, and the first kick-off waits for the current track's first
  /// audio (see [_maybeLogFirstAudio]).
  void _prefetchNeighbors({bool lookahead = false}) {
    try {
      final indices = <int>{};
      void add(int? i) {
        if (i != null && i != state.currentIndex) indices.add(i);
      }

      add(_neighborIndex(1));
      add(_neighborIndex(-1));
      if (lookahead) add(_neighborIndex(2));
      for (final i in indices) {
        _prefetchChain = _prefetchChain.then((_) => _prefetchIndex(i));
      }
    } catch (_) {}
  }

  int? _neighborIndex(int delta) {
    final queue = state.queue;
    if (queue.isEmpty || state.currentIndex < 0 || delta == 0) return null;
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos < 0) return null;
      final next = pos + delta;
      if (next >= 0 && next < _shuffleOrder.length) {
        return _shuffleOrder[next];
      }
      if (state.repeatMode == RepeatMode.all && queue.isNotEmpty) {
        return delta > 0 ? _shuffleOrder.first : _shuffleOrder.last;
      }
      return null;
    }
    final i = state.currentIndex + delta;
    if (i >= 0 && i < queue.length) return i;
    if (state.repeatMode == RepeatMode.all && queue.isNotEmpty) {
      return delta > 0 ? 0 : queue.length - 1;
    }
    return null;
  }

  Future<void> _prefetchIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final track = state.queue[index];
    if (_unavailable.contains(track.queueKey)) return;
    if (_localStream(track) != null) {
      _prefetchArtwork(track);
      return;
    }
    final cacheKey = track.queueKey;
    if (_playCache.get(cacheKey) != null) {
      _prefetchArtwork(track);
      if (track.videoId.isNotEmpty) {
        _tube.prefetchNextTrack(track.videoId);
      }
      return;
    }
    if (!_prefetchInflight.add(track.queueKey)) return;
    // Marks speculative work: a `resolve cache=miss` right after this
    // line came from the prefetcher, not from a click.
    final prefetchSw = Stopwatch()..start();
    _crumb('prefetch start key=${track.queueKey} index=$index');
    try {
      final stream = await _resolveRemote(track);
      prefetchSw.stop();
      _crumb('prefetch done key=${track.queueKey} '
          'ms=${prefetchSw.elapsedMilliseconds} hit=${stream != null}');
      if (stream != null &&
          stream.artworkUrl.isNotEmpty &&
          !(track.album.trim().isNotEmpty &&
              stream.albumTitle.trim().isNotEmpty &&
              !_sameAlbum(track.album, stream.albumTitle))) {
        OfficialArtworkService.instance.rememberTrack(
          title: track.title,
          artist: track.artist,
          artworkUrl: stream.artworkUrl,
          album: stream.albumTitle.isNotEmpty ? stream.albumTitle : track.album,
        );
      }
      _prefetchArtwork(track);
    } catch (_) {
    } finally {
      _prefetchInflight.remove(track.queueKey);
    }
  }

  void _prefetchArtwork(PlayableTrack track) {
    if (OfficialArtworkService.isOfficialArtwork(track.artworkUrl)) return;
    unawaited(_artworkService
        .resolveOfficialArtwork(
      title: track.title,
      artist: track.artist,
      album: track.album,
    )
        .then((_) {}, onError: (_) {}));
  }

  void _maybePrefetchFromPosition(Duration position) {
    final duration = state.duration;
    if (duration.inSeconds < 8) return;
    final remaining = duration - position;
    if (position.inMilliseconds < duration.inMilliseconds * 0.55 &&
        remaining > const Duration(seconds: 28)) {
      return;
    }
    final key = state.current?.queueKey ?? '';
    if (key.isEmpty || key == _prefetchSeedKey) return;
    _prefetchSeedKey = key;
    // Past halfway the third (lookahead) slot is finally cheap enough
    // to fetch: this track's own segments are mostly on disk by now.
    _prefetchNeighbors(lookahead: true);
  }

  /// Loose album equality: "The Odyssey (Original Motion Picture
  /// Soundtrack)" and "The Odyssey" are the same release.
  static bool _sameAlbum(String a, String b) {
    final na = OfficialArtworkService.normalizeForSearch(
        a.replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), ''));
    final nb = OfficialArtworkService.normalizeForSearch(
        b.replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), ''));
    if (na.isEmpty || nb.isEmpty) return true;
    return na == nb || na.contains(nb) || nb.contains(na);
  }

  Future<void> _open(PlayableTrack track, ResolvedStream stream,
      int generation, String wantedQueueKey) async {
    // Stale resolver callbacks must never replace the active track.
    if (generation != _resolveGeneration) return;
    if (_activeQueueKey != wantedQueueKey) return;
    if (state.current?.queueKey != wantedQueueKey &&
        (state.currentIndex < 0 ||
            state.currentIndex >= state.queue.length ||
            state.queue[state.currentIndex].queueKey !=
                wantedQueueKey)) {
      return;
    }
    cancelCrossfade();

    // Upgrade track artwork if the resolved stream supplied official studio artwork
    var effectiveTrack = track;
    // A stream's cover belongs to the catalog row it was matched to; when
    // the queue already knows a different album, that row is another
    // release of the same title (same-named cues on two soundtracks).
    final albumDisagrees = track.album.trim().isNotEmpty &&
        stream.albumTitle.trim().isNotEmpty &&
        !_sameAlbum(track.album, stream.albumTitle);
    if (!albumDisagrees &&
        stream.artworkUrl.isNotEmpty &&
        stream.artworkUrl != track.artworkUrl) {
      effectiveTrack = effectiveTrack.copyWith(
        artworkUrl: stream.artworkUrl,
        album: stream.albumTitle.isNotEmpty && effectiveTrack.album.isEmpty
            ? stream.albumTitle
            : effectiveTrack.album,
      );
      final idx = state.queue.indexWhere((t) => t.queueKey == wantedQueueKey);
      if (idx >= 0) {
        final q = List<PlayableTrack>.of(state.queue);
        q[idx] = effectiveTrack;
        state = state.copyWith(
          queue: q,
          current: idx == state.currentIndex ? effectiveTrack : state.current,
        );
      }
    }
    if (OfficialArtworkService.isOfficialArtwork(effectiveTrack.artworkUrl)) {
      OfficialArtworkService.instance.rememberTrack(
        title: effectiveTrack.title,
        artist: effectiveTrack.artist,
        artworkUrl: effectiveTrack.artworkUrl,
        album: effectiveTrack.album,
      );
    }

    state = state.copyWith(
      current: state.currentIndex >= 0 &&
              state.currentIndex < state.queue.length &&
              state.queue[state.currentIndex].queueKey == wantedQueueKey
          ? effectiveTrack
          : state.current,
      stream: stream,
      bitrateKbps: stream.bitrateKbps,
      isBuffering: true,
      clearError: true,
    );

    // Fetch official studio artwork in the background if current artwork is not official
    if (!OfficialArtworkService.isOfficialArtwork(effectiveTrack.artworkUrl)) {
      _resolveOfficialArtworkInBackground(effectiveTrack, wantedQueueKey, generation);
    }

    try {
      // Pre-open breadcrumb: runs BEFORE the native call, so it
      // survives a segfault. Shape only (kind/ext/mime) — never URLs.
      final rawUrl = stream.url;
      final kind = rawUrl.startsWith('http')
          ? 'remote'
          : (rawUrl.startsWith('file:') ||
                  rawUrl.contains(':\\') ||
                  rawUrl.startsWith('/'))
              ? 'local-file'
              : 'other';
      final ext = rawUrl.split('?').first.split('.').last;
      _crumb('open key=$wantedQueueKey kind=$kind ext=$ext '
          'mime=${stream.mimeType} '
          'cache=${stream.cacheKey}');
      // Materialized manifests arrive as raw `C:\…` paths; mpv opens
      // them, but the backslash form poisons the DASH demux handoff
      // on Windows — always use a file:// URI (mirrors _localStream).
      var playUrl = rawUrl;
      if (kind == 'local-file' && !rawUrl.startsWith('file:')) {
        try {
          playUrl = Uri.file(rawUrl).toString();
          _crumb('open key=$wantedQueueKey file-uri=yes');
        } catch (_) {}
      }
      final wasDash = _lastWasDash;
      final isDash = stream.mimeType.contains('dash');
      int stopMs = 0;
      int loadMs = 0;
      await _serializedMpv(() async {
        // Stale check right before native operations
        if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;

        // Always tear down before loading: opening over a live stream
        // (or racing its teardown) corrupts the Windows libmpv heap —
        // first track plays, the next dies in ntdll.
        final stopSw = Stopwatch()..start();
        try {
          await _player?.stop();
        } catch (_) {}
        stopSw.stop();
        stopMs = stopSw.elapsedMilliseconds;
        if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
        if (wasDash) {
          // Proven crash window (mpv.log): the previous DASH demuxer
          // is still unwinding when loadfile arrives — the second
          // manifest dies mid-probe ~10ms after open. Bounded grace.
          _crumb('open key=$wantedQueueKey dash-grace');
          await Future.delayed(const Duration(milliseconds: 500));
          if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
        }
        // Stamp open-issue BEFORE the call, not after it returns:
        // mpv events (pause=no) and the open() reply travel on separate
        // channels, so playing/position can beat the reply — a stamp
        // taken after `await open()` is fundamentally racy (-1).
        if (generation == _resolveGeneration &&
            _activeQueueKey == wantedQueueKey) {
          _audioOpenDoneAt = DateTime.now();
        }

        // Final sanity check before issuing native loadfile
        if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;

        try {
          await _applyLoudnessTo(_player, album: track.album);
        } catch (_) {}

        Duration? resumeAt;
        if (_resumeKey == wantedQueueKey) {
          resumeAt = _resumeAt;
          _resumeKey = '';
          _resumeAt = null;
          if (resumeAt != null) {
            _crumb('open key=$wantedQueueKey resume=${resumeAt.inSeconds}s');
          }
        }
        final loadSw = Stopwatch()..start();
        await _player?.open(
          Media(playUrl, httpHeaders: stream.requestHeaders, start: resumeAt),
          play: true,
        );
        loadSw.stop();
        loadMs = loadSw.elapsedMilliseconds;
        _lastWasDash = isDash;
      });
      _logTiming('mpv key=$wantedQueueKey kind=$kind '
          'stop_ms=$stopMs load_ms=$loadMs dash_grace=${wasDash ? 500 : 0}');
      if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
      final opened = _player;
      if (opened != null) {
        await _applyLoudnessTo(opened, album: track.album);
        await _applyRateTo(opened);
        unawaited(_captureAlbumGain(track));
      }
    } catch (e, st) {
      if (kDebugMode) {
        final host = Uri.tryParse(stream.url)?.host ?? '?';
        debugPrint(
            'NeoWave-Player: open failed ($host, cache=${stream.cacheKey}): $e');
        debugPrint('NeoWave-Player: open stack: $st');
        _dumpMpvLog('_open.exception');
      }
      if (generation != _resolveGeneration || _activeQueueKey != wantedQueueKey) return;
      await _onPlayerError();
    }
  }

  void _dumpMpvLog(String trigger) {
    if (!kDebugMode) return;
    debugPrint('NeoWave-Player: mpv log tail ($trigger):');
    for (final l in _mpvLogTail) {
      debugPrint('  [${l.prefix}/${l.level}] ${l.text}');
    }
    _mpvLogTail.clear();
  }

  void _resolveOfficialArtworkInBackground(
      PlayableTrack track, String wantedQueueKey, int generation) {
    unawaited(_artworkService
        .resolveOfficialArtwork(
      title: track.title,
      artist: track.artist,
      album: track.album,
    )
        .then((result) {
      if (result == null || result.artworkUrl.isEmpty) return;
      if (generation != _resolveGeneration) return;
      if (_activeQueueKey != wantedQueueKey) return;

      final idx = state.queue.indexWhere((t) => t.queueKey == wantedQueueKey);
      if (idx < 0) return;

      final cur = state.queue[idx];
      final updated = cur.copyWith(
        artworkUrl: result.artworkUrl,
        album: cur.album.isEmpty && result.albumTitle.isNotEmpty
            ? result.albumTitle
            : cur.album,
      );

      final q = List<PlayableTrack>.of(state.queue);
      q[idx] = updated;
      state = state.copyWith(
        queue: q,
        current: idx == state.currentIndex ? updated : state.current,
      );
      _schedulePersist();
    }, onError: (_) {}));
  }

  Future<void> _onPlayerError() async {
    // The outgoing deck died during a crossfade: the incoming deck
    // is already playing, so finish the hand-off instead of restarting
    // the song that was ending anyway.
    if (_crossfading && _standbyReady && _standbyTrack != null) {
      _crumb('mix outgoing error -> early handoff '
          'key=${_standbyTrack?.queueKey}');
      _completeCrossfade();
      return;
    }
    final track = state.current;
    final generation = _resolveGeneration;
    if (track == null || _resolving || state.error != null ||
        _activeQueueKey != track.queueKey ||
        _failedGeneration == generation) {
      return;
    }
    _failedGeneration = generation;
    // Resume a retry where the listener was, not from 0:00.
    final pos = state.position;
    final dur = state.duration;
    if (pos > const Duration(seconds: 3) &&
        (dur == Duration.zero || dur - pos > const Duration(seconds: 5))) {
      _resumeKey = track.queueKey;
      _resumeAt = pos;
    }
    _invalidatePlayCache(track);
    if (track.videoId.isNotEmpty) {
      _tube.reportPlaybackFailure(track.videoId);
    }
    if (_playbackAttempt <= 1) {
      _crumb('retry youtube key=${track.queueKey}');
      await _resolveAndOpen(state.currentIndex,
          forceRefresh: true, attempt: 2);
      return;
    }
    _unavailable.add(track.queueKey);
    await _skipUnavailable(state.currentIndex);
  }

  Future<void> _skipUnavailable(int failedIndex) async {
    final nextIndex = _nextIndex(skipUnavailable: true);
    if (nextIndex == null) {
      state = state.copyWith(
        isBuffering: false,
        isPlaying: false,
        error: 'Track unavailable — end of playable queue.',
      );
      return;
    }
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(nextIndex);
  }

  void _onTrackCompleted() {
    if (_crossfading) {
      _completeCrossfade();
      return;
    }
    cancelCrossfade();
    if (_resolving || state.error != null) return;
    // A late EOF from the stream that was just torn down (retry, skip)
    // lands after the new open has reset position/duration to zero.
    // Advancing on it skipped the track that had only just started.
    final openedAt = _audioOpenDoneAt;
    if (state.duration == Duration.zero &&
        state.position < const Duration(seconds: 2) &&
        (openedAt == null ||
            DateTime.now().difference(openedAt) <
                const Duration(seconds: 3))) {
      final key = state.current?.queueKey ?? '';
      final gen = _resolveGeneration;
      _crumb('stale eof ignored key=$key');
      // If the new stream really is empty it never reports a duration;
      // hand it to the error path then instead of hanging silently.
      Future<void>.delayed(const Duration(seconds: 6), () {
        if (gen != _resolveGeneration || _resolving) return;
        if (state.current?.queueKey != key) return;
        if (state.duration > Duration.zero ||
            state.position > Duration.zero) {
          return;
        }
        unawaited(_onPlayerError());
      });
      return;
    }
    _flushScrobble(completed: true);
    if (state.duration - state.position > const Duration(seconds: 10)) {
      // mpv reported clean EOF far from the known end: a truncated
      // stream, not a finished song (a live stream closed early:
      // Titli died at ~71s of 147s with success reason 2 and the queue
      // skipped ahead). Run the error path instead of advancing — it
      // retries against YouTube. Repeat-one is covered too: its replay
      // below would loop the broken prefix.
      _crumb('premature eof pos=${state.position.inSeconds}s '
          'dur=${state.duration.inSeconds}s key=${state.current?.queueKey}');
      unawaited(_onPlayerError());
      return;
    }
    if (state.repeatMode == RepeatMode.one) {
      final loopTrack = state.current;
      seek(Duration.zero);
      playResume();
      if (loopTrack != null) {
        // Re-arm a fresh scrobble window for the looped play.
        _beginScrobbleWindow(loopTrack);
      }
      return;
    }
    final nextIndex = _nextIndex();
    if (nextIndex == null) {
      state = state.copyWith(isPlaying: false);
      _schedulePersist();
      return;
    }
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    _resolveAndOpen(nextIndex);
  }

  /// Shuffle orders can outlive queue edits (remove/reorder during
  /// resolve churn). Stale indices must never reach `queue[i]`: a
  /// RangeError inside an mpv callback aborts the whole process.
  bool _queueIndexValid(int i) =>
      i >= 0 && i < state.queue.length;

  int? _nextIndex({bool skipUnavailable = false}) {
    final queue = state.queue;
    if (queue.isEmpty || state.currentIndex < 0) return null;
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos >= 0 && pos + 1 < _shuffleOrder.length) {
        final candidate = _shuffleOrder[pos + 1];
        if (!_queueIndexValid(candidate)) {
          return _wrapIndex(skipUnavailable: skipUnavailable);
        }
        if (skipUnavailable &&
            _unavailable.contains(queue[candidate].queueKey)) {
          // walk forward past unavailable
          for (var i = pos + 1; i < _shuffleOrder.length; i++) {
            final idx = _shuffleOrder[i];
            if (!_queueIndexValid(idx)) continue;
            if (!_unavailable.contains(queue[idx].queueKey)) {
              return idx;
            }
          }
          return _wrapIndex(skipUnavailable: skipUnavailable);
        }
        return candidate;
      }
      return _wrapIndex(skipUnavailable: skipUnavailable);
    }
    final next = state.currentIndex + 1;
    if (next < queue.length) {
      if (skipUnavailable &&
          _unavailable.contains(queue[next].queueKey)) {
        for (var i = next; i < queue.length; i++) {
          if (!_unavailable.contains(queue[i].queueKey)) return i;
        }
        return _wrapIndex(skipUnavailable: skipUnavailable);
      }
      return next;
    }
    return _wrapIndex(skipUnavailable: skipUnavailable);
  }

  int? _wrapIndex({bool skipUnavailable = false}) {
    if (state.repeatMode != RepeatMode.all) return null;
    final order = state.shuffleEnabled && _shuffleOrder.isNotEmpty
        ? _shuffleOrder
        : List<int>.generate(state.queue.length, (index) => index);
    for (final index in order) {
      if (!_queueIndexValid(index)) continue;
      if (!skipUnavailable ||
          !_unavailable.contains(state.queue[index].queueKey)) {
        return index;
      }
    }
    return null;
  }

  int? _prevIndex() {
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos > 0) {
        final prev = _shuffleOrder[pos - 1];
        return _queueIndexValid(prev) ? prev : null;
      }
      return null;
    }
    if (state.currentIndex > 0) return state.currentIndex - 1;
    return null;
  }

  void _rebuildShuffleOrder(int length, int currentIndex) {
    _shuffleOrder =
        List<int>.generate(length, (i) => i)..shuffle();
    if (currentIndex >= 0 && currentIndex < length) {
      _shuffleOrder.remove(currentIndex);
      _shuffleOrder.insert(0, currentIndex);
    }
  }

  // -- endless radio ---------------------------------------------------------------

  Future<void> _maybeRefillRadio() async {
    if (!_endlessRadio) return;
    final remaining = state.queue.length - state.currentIndex - 1;
    if (remaining > 6) return;
    final seed = state.current;
    if (seed == null || _radioSeeds.contains(seed.mediaId)) return;
    _radioSeeds.add(seed.mediaId);
    try {
      final videoId = seed.videoId.isNotEmpty
          ? seed.videoId
          : (await _tube.findBestMatchOrNull(seed.title, seed.artist))
              ?.videoId;
      if (videoId == null) return;
      final related =
          await _tube.fetchRelatedSongs(videoId, limit: 25);
      final current = state.queue;
      final fresh = related
          .where((t) =>
              !_isDisallowedRadioTitle(t.title) &&
              !_isRadioDuplicate(t, current) &&
              !_radioSeeds.contains(t.videoId))
          .take(10)
          .map((t) => PlayableTrack(
                title: t.title,
                artist: t.artist,
                album: t.album,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ))
          .toList();
      if (fresh.isEmpty) return;
      final queue = [...state.queue, ...fresh];
      _rebuildShuffleOrder(queue.length, state.currentIndex);
      state = state.copyWith(queue: queue);
      _schedulePersist();
    } catch (_) {}
  }

  bool _isDisallowedRadioTitle(String title) {
    final t = title.toLowerCase();
    return t.contains('mashup') ||
        t.contains('jukebox') ||
        t.contains('megamix') ||
        t.contains('nonstop') ||
        t.contains('all songs') ||
        t.contains('compilation');
  }

  /// Radio duplicate check with fuzzy matching: exact lowercase keys
  /// miss artist variants ("X - Topic", feat. credits) and title
  /// suffixes, which then play the same song twice in a row. Same
  /// 85/50 thresholds as the library matching in `fillMissingMetadata`.
  bool _isRadioDuplicate(
      YouTubeMusicTrack t, List<PlayableTrack> queue) {
    final key =
        '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
    final base = InnerTubeMusicApi.baseTitle(t.title);
    for (final q in queue) {
      if (q.queueKey == key) return true;
      if (InnerTubeMusicApi.similarity(
              InnerTubeMusicApi.baseTitle(q.title), base) <
          85) {
        continue;
      }
      final qa = q.artist.toLowerCase();
      final ta = t.artist.toLowerCase();
      if (qa.isNotEmpty &&
          ta.isNotEmpty &&
          (qa.contains(ta) ||
              ta.contains(qa) ||
              InnerTubeMusicApi.similarity(qa, ta) >= 50)) {
        return true;
      }
    }
    return false;
  }

  // -- scrobbling ---------------------------------------------------------------

  void _onPlayingChanged(bool playing) {
    _lastTick = playing ? DateTime.now() : null;
    if (!playing) {
      _schedulePersist();
    } else if (state.current != null) {
      if (!_nowPlayingSent) {
        _sendNowPlaying(state.current!);
      }
    }
  }

  void _beginScrobbleWindow(PlayableTrack track) {
    // On-device play log for the keyless-guest taste algorithm.
    // Runs for every listener (not just Last.fm users); the DB call
    // is a single indexed insert, never on the audio path.
    try {
      _sessions.recordLocalPlay(track.title, track.artist);
    } catch (_) {}
    _flushScrobble(completed: false);
    _scrobbleTrack = track;
    _scrobbleDurationSec = state.duration.inSeconds;
    // If the new track already has a known duration in state (rare,
    // e.g. replay), prefer it; otherwise keep 0 and let the duration
    // listener fill it in.
    if (_scrobbleTrack!.queueKey == state.current?.queueKey) {
      _scrobbleDurationSec = state.duration.inSeconds;
    }
    _scrobbleStartEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _accumulatedSeconds = 0;
    _scrobbledThisWindow = false;
    _ytHistoryPushedThisWindow = false;
    _ytHistoryAttempts = 0;
    _ytHistoryCpn = '';
    _nowPlayingSent = false;
    _lastTick = DateTime.now();
    _sendNowPlaying(track);
    _prewarmHistoryId(track);
  }

  void _sendNowPlaying(PlayableTrack track) {
    _nowPlayingSent = true;
    unawaited(_scrobbler.updateNowPlaying(
      artist: track.artist,
      track: track.title,
      album: track.album,
    ));
  }

  /// Push the window's track into the YT Music watch history: a single
  /// ping per window, fired alongside the scrobble so only real
  /// listens sync. Repeats would file duplicates.
  /// Failures reset the flag so the flush site retries once.
  /// No-throw throughout.
  void _maybePushYtHistory(
      PlayableTrack track, int watchedSeconds,
      {int durationSeconds = 0}) {
    if (_ytHistoryPushedThisWindow) return;
    if (_ytHistoryAttempts >= 2) return;
    if (!_prefs.syncYtHistory) return;
    // Signed out to YouTube: nothing can be filed, and the search below
    // would hit the network on every tick. Checked before the claim.
    if (!_tube.connection.connected) return;
    // Claim the window before the async resolve so concurrent sites
    // (threshold + flush) don't double-search. Failures below reset
    // the flag for a retry at the next site (capped above).
    _ytHistoryPushedThisWindow = true;
    _ytHistoryAttempts++;
    unawaited(
        _pushYtHistoryAsync(track, watchedSeconds, durationSeconds));
  }

  Future<void> _pushYtHistoryAsync(
      PlayableTrack track, int watchedSeconds, int durationSeconds) async {
    var videoId = _windowVideoId(track);
    if (videoId.isEmpty) {
      // Local-file plays may never have matched a YouTube video.
      // Resolve on demand (disk-cached after the first match, so one
      // search per track ever) and adopt it — future plays then take
      // the instant path everywhere, not just history.
      videoId = await _matchYoutubeIdForHistory(track);
    }
    if (videoId.isEmpty) {
      _ytHistoryPushedThisWindow = false;
      return;
    }
    // No usable base yet: fetch one minted under the account
    // (anonymous direct-client bases are accepted
    // but filed nowhere). One authenticated player call per window.
    var watchUrl = _watchtimeUrls[videoId] ?? '';
    if (watchUrl.isEmpty) {
      try {
        watchUrl = await _tube
            .fetchAuthenticatedPlaybackUrl(videoId)
            .timeout(const Duration(seconds: 30));
        if (watchUrl.isNotEmpty) {
          _stashWatchtimeUrl(videoId, watchUrl);
        } else if (kDebugMode) {
          debugPrint('YtHistory: authed fetch yielded no base $videoId');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
              'YtHistory: authed fetch threw ${e.runtimeType} $videoId');
        }
        watchUrl = '';
      }
    }
    final ok = await _tube.recordWatchHistory(
        videoId: videoId,
        watchedSeconds: watchedSeconds,
        durationSeconds: durationSeconds,
        cpn: _historyCpn(),
        watchUrl: watchUrl);
    if (!ok) _ytHistoryPushedThisWindow = false;
  }

  /// YouTube video for a track that was NOT played from YouTube (local
  /// file…): strict match first, then the looser "best
  /// effort" match, so history still gets the right song. Adopted into the
  /// queue so later plays take the instant path.
  Future<String> _matchYoutubeIdForHistory(PlayableTrack track) async {
    try {
      var match = await _tube
          .findBestMatchOrNull(track.title, track.artist)
          .timeout(const Duration(seconds: 12));
      match ??= await _tube
          .findBestEffortMatchOrNull(track.title, track.artist)
          .timeout(const Duration(seconds: 12));
      final id = match?.videoId ?? '';
      if (id.isNotEmpty) _adoptVideoId(track, id, match!);
      return id;
    } catch (_) {
      return '';
    }
  }

  /// Resolve the history video early for non-YouTube plays, so it is ready
  /// by the time the 20s mark files the ping.
  void _prewarmHistoryId(PlayableTrack track) {
    if (!_prefs.syncYtHistory || _windowVideoId(track).isNotEmpty) return;
    if (!_tube.connection.connected) return;
    unawaited(_matchYoutubeIdForHistory(track));
  }

  /// One client playback nonce per scrobble window.
  String _historyCpn() {
    if (_ytHistoryCpn.isEmpty) {
      _ytHistoryCpn = InnerTubeMusicApi.newWatchCpn();
    }
    return _ytHistoryCpn;
  }

  /// videoId for the window's track. The `_scrobbleTrack` snapshot may
  /// predate match adoption (immutable copy), so prefer the live queue
  /// entry, which `_adoptVideoId` keeps current.
  String _windowVideoId(PlayableTrack track) {
    if (track.videoId.isNotEmpty) return track.videoId;
    try {
      for (final q in state.queue) {
        if (q.queueKey == track.queueKey && q.videoId.isNotEmpty) {
          return q.videoId;
        }
      }
    } catch (_) {}
    return '';
  }

  void _tickScrobble(Duration position) {
    final last = _lastTick;
    final now = DateTime.now();
    if (last != null && state.isPlaying) {
      _accumulatedSeconds +=
          now.difference(last).inMilliseconds / 1000.0;
    }
    _lastTick = now;

    // YouTube Music history is filed as soon as the song has really been
    // played (20s), not at the Last.fm scrobble threshold — that is up to
    // half the song, so short listens and quick skips never reached the
    // account's history at all.
    if (_scrobbleStartEpoch != 0 &&
        !_ytHistoryPushedThisWindow &&
        _scrobbleTrack != null &&
        state.isPlaying &&
        _accumulatedSeconds >= 20) {
      _maybePushYtHistory(
        _scrobbleTrack!,
        _accumulatedSeconds.round(),
        durationSeconds: _scrobbleDurationSec > 0
            ? _scrobbleDurationSec
            : state.duration.inSeconds,
      );
    }

    // Eager scrobble at threshold so manual pause still appears in
    // history (Last.fm otherwise expires “Scrobbling now” on pause).
    if (_scrobbleStartEpoch != 0 &&
        !_scrobbledThisWindow &&
        _scrobbleTrack != null &&
        state.isPlaying) {
      final durationSec = _scrobbleDurationSec > 0
          ? _scrobbleDurationSec
          : state.duration.inSeconds;
      if (durationSec > 0) {
        final percent = _prefs.scrobblePercent.clamp(25, 90);
        final threshold =
            (durationSec * percent / 100).round().clamp(30, 240);
        if (_accumulatedSeconds >= threshold) {
          _scrobbledThisWindow = true;
          final t = _scrobbleTrack!;
          unawaited(_scrobbler.scrobble(
            artist: t.artist,
            track: t.title,
            album: t.album,
            timestampSec: _scrobbleStartEpoch,
          ));
          _maybePushYtHistory(t, threshold, durationSeconds: durationSec);
        }
      } else if (_accumulatedSeconds >= 30) {
        // Duration still unknown — fall back to Last.fm’s 30s floor
        // so long tracks don’t wait indefinitely on metadata.
        _scrobbledThisWindow = true;
        final t = _scrobbleTrack!;
        unawaited(_scrobbler.scrobble(
          artist: t.artist,
          track: t.title,
          album: t.album,
          timestampSec: _scrobbleStartEpoch,
        ));
        _maybePushYtHistory(t, 30);
      }
    }
  }

  void _flushScrobble({required bool completed}) {
    final track = _scrobbleTrack ?? state.current;
    if (track == null || _scrobbleStartEpoch == 0) return;
    if (_scrobbledThisWindow) {
      // Already scrobbled eagerly at threshold — just tear down window.
      // Still attempt the YT push: the eager push may have failed and
      // reset its flag (success is a no-op here).
      _maybePushYtHistory(track, _accumulatedSeconds.round(),
          durationSeconds: _scrobbleDurationSec);
      _scrobbleStartEpoch = 0;
      _accumulatedSeconds = 0;
      _scrobbleTrack = null;
      _scrobbleDurationSec = 0;
      _scrobbledThisWindow = false;
      return;
    }
    // Duration belongs to the scrobble window, not necessarily
    // state.duration (which may already be 0 for the next track).
    final durationSec = _scrobbleDurationSec > 0
        ? _scrobbleDurationSec
        : state.duration.inSeconds;
    final percent = _prefs.scrobblePercent.clamp(25, 90);
    // Last.fm rule: min(duration*percent/100, 240) clamped to at least 30s.
    final threshold = durationSec > 0
        ? (durationSec * percent / 100).round().clamp(30, 240)
        : 30;
    final playedEnough = _accumulatedSeconds >= threshold ||
        (completed && _accumulatedSeconds >= 30);
    if (playedEnough) {
      unawaited(_scrobbler.scrobble(
        artist: track.artist,
        track: track.title,
        album: track.album,
        timestampSec: _scrobbleStartEpoch,
      ));
      _maybePushYtHistory(track, _accumulatedSeconds.round(),
          durationSeconds: durationSec);
    }
    _scrobbleStartEpoch = 0;
    _accumulatedSeconds = 0;
    _scrobbleTrack = null;
    _scrobbleDurationSec = 0;
    _scrobbledThisWindow = false;
  }

  // -- persistence ---------------------------------------------------------------

  void _schedulePersist() {
    final now = DateTime.now();
    if (now.difference(_lastPersist) < const Duration(seconds: 2)) {
      _persistThrottle?.cancel();
      _persistThrottle = Timer(
        const Duration(seconds: 2),
        () => _schedulePersist(),
      );
      return;
    }
    _lastPersist = now;
    _persistNow();
  }

  void _persistNow() {
    if (state.queue.isEmpty || state.currentIndex < 0) return;
    final start =
        (state.currentIndex - 50).clamp(0, state.queue.length);
    final end =
        (start + 200).clamp(0, state.queue.length);
    _sessions.save({
      'version': 2,
      'queue': state.queue
          .sublist(start, end)
          .map((t) => t.toJson())
          .toList(),
      'currentIndex': state.currentIndex - start,
      'positionMs': state.position.inMilliseconds,
      'sourceLabel': state.sourceLabel,
      'endless': _endlessRadio,
      'shuffle': state.shuffleEnabled,
      'repeat': state.repeatMode.index,
      'speed': state.speed,
    });
  }

  Future<void> restoreSession() async {
    final data = _sessions.load();
    final queueJson = data['queue'];
    if (queueJson is! List || queueJson.isEmpty) return;
    final queue = queueJson
        .whereType<Map<String, dynamic>>()
        .map(PlayableTrack.fromJson)
        .where((t) => t.title.isNotEmpty)
        .toList();
    if (queue.isEmpty) return;
    final index = ((data['currentIndex'] as num?)?.toInt() ?? 0)
        .clamp(0, queue.length - 1);
    _endlessRadio = data['endless'] == true;
    _rebuildShuffleOrder(queue.length, index);
    state = state.copyWith(
      queue: queue,
      currentIndex: index,
      current: queue[index],
      sourceLabel: data['sourceLabel']?.toString() ?? '',
      shuffleEnabled: data['shuffle'] == true,
      repeatMode: RepeatMode
          .values[((data['repeat'] as num?)?.toInt() ?? 0)
              .clamp(0, RepeatMode.values.length - 1)],
      speed: (((data['speed'] as num?)?.toDouble() ?? 1.0)
              .clamp(0.5, 2.0))
          .toDouble(),
      position: Duration(
          milliseconds: ((data['positionMs'] as num?)?.toInt() ?? 0)
              .clamp(0, 1 << 31)),
    );
  }
}

/// Thin prefs/session adapters to keep the service testable.
/// Wraps live [Prefs] so scrobble thresholds and quality choices
/// reflect SharedPreferences changes without recreating the service.
class PrefsHandle {
  final Prefs _prefs;
  PrefsHandle(this._prefs);
  int get streamQuality => _prefs.streamQuality;
  int get scrobblePercent => _prefs.scrobblePercent;
  bool get scrobblerEnabled => _prefs.scrobblerEnabled;
  bool get syncYtHistory => _prefs.syncYtHistory;
  bool get crossfadeEnabled => _prefs.crossfadeEnabled;
  int get crossfadeSeconds => _prefs.crossfadeSeconds;
  String get loudnessMode => _prefs.loudnessMode;
  bool get equalizerEnabled => _prefs.equalizerEnabled;
  bool get studioClarityEnabled => _prefs.studioClarityEnabled;
  Prefs get rawPrefs => _prefs;
}

class SessionStore {
  final AppDatabase _db;
  SessionStore(this._db);
  Map<String, dynamic> load() => _db.loadPlaybackSession();
  void save(Map<String, dynamic> payload) =>
      _db.savePlaybackSession(payload);
  void clear() => _db.clearPlaybackSession();
  void recordLocalPlay(String title, String artist) =>
      _db.recordLocalPlay(title: title, artist: artist);
}

final playbackServiceProvider =
    StateNotifierProvider<PlaybackService, PlayerSnapshot>((ref) {
  final service = PlaybackService(
    ref.watch(innerTubeProvider),
    ref.watch(scrobbleRepositoryProvider),
    ref.watch(downloadManagerProvider.notifier),
    PrefsHandle(ref.watch(prefsProvider)),
    SessionStore(ref.watch(databaseProvider)),
    ref.watch(officialArtworkServiceProvider),
  );
  ref.onDispose(() {
    unawaited(service.disposePlayer());
  });
  return service;
});