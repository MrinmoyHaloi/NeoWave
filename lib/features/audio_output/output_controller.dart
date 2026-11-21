import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';

class AudioOutputState {
  /// mpv's own device list. Names are mpv device names (e.g. `wasapi/{id}`
  /// on Windows); the empty selection is the system default.
  final List<AudioDevice> devices;
  final String selectedId;

  const AudioOutputState({
    this.devices = const [],
    this.selectedId = '',
  });

  AudioDevice? get selected {
    for (final d in devices) {
      if (d.name == selectedId) return d;
    }
    return null;
  }

  String get selectedLabel => selected?.description ?? 'System default';

  AudioOutputState copyWith({
    List<AudioDevice>? devices,
    String? selectedId,
  }) =>
      AudioOutputState(
        devices: devices ?? this.devices,
        selectedId: selectedId ?? this.selectedId,
      );
}

/// Chooses the mpv output device and passes volume and mute to playback.
class AudioOutputController extends StateNotifier<AudioOutputState> {
  final Ref _ref;
  StreamSubscription<List<AudioDevice>>? _devicesSub;
  bool _attached = false;
  // Last non-zero volume, so unmute restores the pre-mute level
  // instead of full blast. Updated on every audible setVolume and
  // on every mute press (covers slider-dragged-to-zero too).
  double _preMuteVolume = 1.0;

  AudioOutputController(this._ref) : super(const AudioOutputState()) {
    state = state.copyWith(
      selectedId: _ref.read(prefsProvider).audioDeviceId,
    );
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    super.dispose();
  }

  /// mpv's own `auto` entry ("Autoselect device") is what the UI's
  /// "System default" row already selects, so listing it would duplicate it.
  static List<AudioDevice> _selectable(List<AudioDevice> devices) =>
      [for (final d in devices) if (d.name != 'auto') d];

  /// Called once at startup: reads mpv's device list, follows changes, and
  /// routes playback to the saved device.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    final playback = _ref.read(playbackServiceProvider.notifier);
    state = state.copyWith(devices: _selectable(playback.audioDevices));
    _devicesSub = playback.audioDeviceChanges.listen((devices) {
      state = state.copyWith(devices: _selectable(devices));
    });
    final saved = state.selectedId;
    if (saved.isEmpty) return;
    if (state.devices.any((d) => d.name == saved)) {
      await playback.setOutputDevice(saved);
    } else if (state.devices.isNotEmpty) {
      // Unknown to mpv: fall back to the system default.
      await selectDevice('');
    }
  }

  Future<void> selectDevice(String id) async {
    await _ref.read(prefsProvider).setAudioDeviceId(id);
    state = state.copyWith(selectedId: id);
    await _ref
        .read(playbackServiceProvider.notifier)
        .setOutputDevice(id.isEmpty ? 'auto' : id);
  }

  Future<void> setVolume(double volume) async {
    if (volume > 0) _preMuteVolume = volume.clamp(0.0, 1.0);
    await _ref.read(playbackServiceProvider.notifier).setVolume(volume);
  }

  /// Mute toggle: mute remembers the current level, unmute restores it
  /// (never jumps to max). No history yet (e.g. slider dragged to zero
  /// then toggled) falls back to full volume.
  Future<void> toggleMute() async {
    final current = _ref.read(playbackServiceProvider).volume;
    if (current <= 0) {
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 1.0);
    } else {
      _preMuteVolume = current;
      await setVolume(0);
    }
  }
}

final audioOutputProvider =
    StateNotifierProvider<AudioOutputController, AudioOutputState>((ref) {
  return AudioOutputController(ref);
});
