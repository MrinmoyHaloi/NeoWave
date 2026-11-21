import '../../core/audio/stream_models.dart';

/// Immutable playback snapshot consumed by the UI.
/// Mirrors Android `MusicPlayerState` (tracker-friendly subset).
class PlayerSnapshot {
  final PlayableTrack? current;
  final List<PlayableTrack> queue;
  final int currentIndex;
  final String sourceLabel;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration buffered;
  final Duration duration;
  final bool shuffleEnabled;
  final RepeatMode repeatMode;
  final double speed;
  final ResolvedStream? stream;
  final String? error;
  final Duration? sleepRemaining;
  /// Length the user picked, in minutes. Null while the timer is off.
  /// Stays put as [sleepRemaining] counts down so the menu can keep
  /// the chosen row checked.
  final int? sleepMinutes;
  final int bitrateKbps;
  final double volume;

  const PlayerSnapshot({
    this.current,
    this.queue = const [],
    this.currentIndex = -1,
    this.sourceLabel = '',
    this.isPlaying = false,
    this.isBuffering = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.duration = Duration.zero,
    this.shuffleEnabled = false,
    this.repeatMode = RepeatMode.off,
    this.speed = 1.0,
    this.stream,
    this.error,
    this.sleepRemaining,
    this.sleepMinutes,
    this.bitrateKbps = 0,
    this.volume = 1.0,
  });

  PlayerSnapshot copyWith({
    PlayableTrack? current,
    bool clearCurrent = false,
    List<PlayableTrack>? queue,
    int? currentIndex,
    String? sourceLabel,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? buffered,
    Duration? duration,
    bool? shuffleEnabled,
    RepeatMode? repeatMode,
    double? speed,
    ResolvedStream? stream,
    bool clearStream = false,
    String? error,
    bool clearError = false,
    Duration? sleepRemaining,
    int? sleepMinutes,
    bool clearSleep = false,
    int? bitrateKbps,
    double? volume,
  }) =>
      PlayerSnapshot(
        current: clearCurrent ? null : (current ?? this.current),
        queue: queue ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        sourceLabel: sourceLabel ?? this.sourceLabel,
        isPlaying: isPlaying ?? this.isPlaying,
        isBuffering: isBuffering ?? this.isBuffering,
        position: position ?? this.position,
        buffered: buffered ?? this.buffered,
        duration: duration ?? this.duration,
        shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
        repeatMode: repeatMode ?? this.repeatMode,
        speed: speed ?? this.speed,
        stream: clearStream ? null : (stream ?? this.stream),
        error: clearError ? null : (error ?? this.error),
        sleepRemaining:
            clearSleep ? null : (sleepRemaining ?? this.sleepRemaining),
        sleepMinutes: clearSleep ? null : (sleepMinutes ?? this.sleepMinutes),
        bitrateKbps: bitrateKbps ?? this.bitrateKbps,
        volume: volume ?? this.volume,
      );
}
