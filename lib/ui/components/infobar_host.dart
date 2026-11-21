import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/network_monitor.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_session_keeper.dart';
import '../../features/lastfm/auth_repository.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';
import 'buttons.dart';

/// Global Fluent InfoBar host — non-blocking feedback docked above content.
///
/// Shows (highest priority first):
/// - offline network
/// - Last.fm session expired
/// - latest download done/error
///
/// Dismissible per-bar, auto-collapses when clear. Rendered by [WaveShell]
/// as a frosted overlay at the top of the content, so it floats over the
/// page instead of pushing it down, and never blocks playback.
/// One-shot "running in the tray" hint, set on first hide-to-tray.
/// Session-scoped (resets on relaunch) — the pref itself lives in Prefs.
final trayHintProvider = StateProvider<bool>((_) => false);

class WaveInfoBarHost extends ConsumerStatefulWidget {
  const WaveInfoBarHost({super.key});
  @override
  ConsumerState<WaveInfoBarHost> createState() => _WaveInfoBarHostState();
}

class _WaveInfoBarHostState extends ConsumerState<WaveInfoBarHost> {
  bool _dismissedOffline = false;
  bool _dismissedAuth = false;
  bool _dismissedYt = false;
  String? _dismissedDownloadKey;
  bool _ytRecovering = false;

  @override
  void initState() {
    super.initState();
    // The stale flag may already be set before this host mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(ytAuthStaleProvider)) _recoverYt();
    });
  }

  /// A restart (every setup/portable update is one) often brings back
  /// a stored YouTube jar Google has already rotated out. Before
  /// telling the user to sign in again, try once per run to re-mint it
  /// silently from the persisted WebView2 profile.
  Future<void> _recoverYt() async {
    if (_ytRecovering || YtSessionKeeper.autoAttempted) return;
    if (!ref.read(ytConnectionProvider).connected) return;
    setState(() => _ytRecovering = true);
    try {
      await YtSessionKeeper.autoRecover(ref);
    } finally {
      if (mounted) setState(() => _ytRecovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(ytAuthStaleProvider, (prev, stale) {
      if (stale && prev != true) _recoverYt();
    });
    final online = ref.watch(networkMonitorProvider);
    final auth = ref.watch(authRepositoryProvider);
    final downloads = ref.watch(downloadManagerProvider);

    final bars = <Widget>[];
    if (ref.watch(trayHintProvider)) {
      bars.add(InfoBar(
        title: const Text('Playing in the tray'),
        content: const Text(
            'Closing hides NeoWave — Quit from the tray menu to exit.'),
        severity: InfoBarSeverity.info,
        isLong: false,
        onClose: () =>
            ref.read(trayHintProvider.notifier).state = false,
      ));
    }
    if (!online && !_dismissedOffline) {
      bars.add(InfoBar(
        title: const Text('You are offline'),
        content: const Text('Charts and streaming may be unavailable.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        onClose: () => setState(() => _dismissedOffline = true),
      ));
    }
    // Guests chose keyless entry — never nag them about Last.fm.
    if (auth.status != AuthStatus.signedIn &&
        auth.status != AuthStatus.guest &&
        !_dismissedAuth) {
      bars.add(InfoBar(
        title: const Text('Last.fm disconnected'),
        content: const Text('Connect to keep scrobbling and picks.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        action: WaveLink(
          onPressed: () => context.go('/welcome'),
          child: const Text('Connect'),
        ),
        onClose: () => setState(() => _dismissedAuth = true),
      ));
    }
    // YouTube Music session the server has rejected. Not silent noise:
    // library, history and uploads all stay empty until this is fixed.
    if (ref.watch(ytConnectionProvider).connected &&
        ref.watch(ytAuthStaleProvider) &&
        _ytRecovering) {
      bars.add(const InfoBar(
        title: Text('Reconnecting YouTube Music…'),
        content: Text('Refreshing the saved session in the background.'),
        severity: InfoBarSeverity.info,
        isLong: false,
      ));
    } else if (ref.watch(ytConnectionProvider).connected &&
        ref.watch(ytAuthStaleProvider) &&
        !_dismissedYt) {
      bars.add(InfoBar(
        title: const Text('YouTube Music session expired'),
        content: const Text(
            'Reconnect to load your library, history and uploads again.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        action: WaveLink(
          onPressed: () => context.go('/settings?section=integrations'),
          child: const Text('Reconnect'),
        ),
        onClose: () => setState(() => _dismissedYt = true),
      ));
    }
    DownloadEntry? latest;
    for (final d in downloads) {
      if (d.status == DownloadStatus.done ||
          d.status == DownloadStatus.error) {
        latest = d;
      }
    }
    // Restored-at-boot rows are history (see DownloadManager._muted) —
    // only entries that finished this session may announce.
    final announcer = ref.read(downloadManagerProvider.notifier);
    if (latest != null &&
        _dismissedDownloadKey != latest.key &&
        announcer.shouldAnnounce(latest.key)) {
      final entry = latest;
      bars.add(InfoBar(
        title: Text(entry.status == DownloadStatus.done
            ? 'Download complete'
            : 'Download failed'),
        content: Text('${entry.title} — ${entry.artist}'),
        severity: entry.status == DownloadStatus.done
            ? InfoBarSeverity.success
            : InfoBarSeverity.error,
        isLong: false,
        action: WaveLink(
          onPressed: () => context.go('/downloads'),
          child: const Text('Open'),
        ),
        onClose: () {
          announcer.muteAnnouncement(entry.key);
          setState(() => _dismissedDownloadKey = entry.key);
        },
      ));
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: InfoBarTheme(
        data: _floatingStyle(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kBarMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < bars.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _floating(bars[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Frosted, rounded, shadowed chrome for one bar. The bar's own
  /// decoration is replaced by [_floatingStyle] so its corners match the
  /// haze clip; the haze shows the page blurred behind the bar. The shadow
  /// sits on an outer box because the haze clips its children, which would
  /// cut off a shadow painted inside it.
  Widget _floating(Widget bar) {
    final radius = BorderRadius.circular(WaveRadius.menu);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: WaveHaze(
        level: NwHazeLevel.l2,
        borderRadius: radius,
        child: bar,
      ),
    );
  }
}

/// Widest a status bar grows before its text wraps. Bars size to their
/// content so the close button lands at each bar's right edge.
const double _kBarMaxWidth = 640;

/// Rounded InfoBar decoration. The severity fill is thinned so the frost
/// behind shows through; an opaque fill hid the blur entirely.
InfoBarThemeData _floatingStyle(BuildContext context) {
  final resources = FluentTheme.of(context).resources;
  return InfoBarThemeData(
    decoration: (severity) {
      final color = switch (severity) {
        InfoBarSeverity.info => resources.systemFillColorAttentionBackground,
        InfoBarSeverity.warning => resources.systemFillColorCautionBackground,
        InfoBarSeverity.success => resources.systemFillColorSuccessBackground,
        InfoBarSeverity.error => resources.systemFillColorCriticalBackground,
      };
      return BoxDecoration(
        color: color.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        border: Border.all(color: resources.cardStrokeColorDefault),
      );
    },
  );
}
