import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Branch container for the shell's `StatefulShellRoute`.
///
/// go_router's default `IndexedStack` keeps every branch mounted (scroll and
/// page state survive) but swaps branches with no motion. This container
/// keeps that keep-alive contract and adds the app's motion language: the
/// incoming branch fades in and rises 6px over [WaveMotion.normal] while the
/// outgoing one fades out beneath it. The rail, title bar and dock stay put.
///
/// Each branch keeps one stable wrapper shape (ignore, offstage, ticker,
/// fade) so an index change flips properties, never widget types; changing
/// a wrapper's type would rebuild the branch and lose its state. Branches
/// that are neither incoming nor outgoing are `Offstage` and ticker-muted.
///
/// Honours the OS reduce-motion switch (`MediaQuery.disableAnimations`):
/// the switch is then instant.
class WaveBranchSwitcher extends StatefulWidget {
  const WaveBranchSwitcher({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  /// Active branch index (`StatefulNavigationShell.currentIndex`).
  final int currentIndex;

  /// Branch navigator widgets, one per `StatefulShellBranch`.
  final List<Widget> children;

  @override
  State<WaveBranchSwitcher> createState() => _WaveBranchSwitcherState();
}

class _WaveBranchSwitcherState extends State<WaveBranchSwitcher>
    with SingleTickerProviderStateMixin {
  /// 0 → the incoming branch is fully transparent, 1 → settled.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: waveMotion(context, WaveMotion.normal),
    value: 1,
  );

  /// Branch fading out, or null when the switch has settled.
  int? _leaving;

  /// Mirrored from [build] so [didUpdateWidget] can honour the OS switch
  /// without reaching for an inherited widget outside a build.
  bool _reducedMotion = false;

  @override
  void didUpdateWidget(covariant WaveBranchSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex == widget.currentIndex) return;
    if (_reducedMotion) {
      setState(() => _leaving = null);
      _fade.value = 1;
      return;
    }
    setState(() => _leaving = oldWidget.currentIndex);
    _fade.value = 0;
    _fade.forward().whenComplete(() {
      if (mounted) setState(() => _leaving = null);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Widget _branch(int i, double rise) {
    final active = i == widget.currentIndex;
    final visible = active || _leaving == i;
    // Offstage only hides: a hidden page's controls stay in the focus tree, so
    // Tab ran off the end of the visible page into every other mounted page.
    // ExcludeFocus is always present (only its flag flips) to keep the wrapper
    // shape stable.
    return ExcludeFocus(
      excluding: !active,
      child: IgnorePointer(
      ignoring: !active,
      child: Offstage(
        offstage: !visible,
        child: TickerMode(
          enabled: active,
          child: AnimatedBuilder(
            animation: _fade,
            child: widget.children[i],
            builder: (context, child) {
              final t = _reducedMotion
                  ? 1.0
                  : Curves.easeOutCubic.transform(_fade.value);
              // Opacity + FractionalTranslation are always present, for every
              // branch, at every value: a stable wrapper shape is what keeps
              // the branch element (and its scroll offset, its state) alive.
              // Both are free at rest — opacity 1 paints straight through and
              // a zero fractional translation is a plain offset. The rise
              // belongs to the incoming branch only.
              return Opacity(
                opacity: active ? t : 1 - t,
                child: FractionalTranslation(
                  translation: Offset(0, active ? rise * (1 - t) : 0),
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // 6 logical pixels of rise, expressed as a fraction of the branch height
    // (FractionalTranslation offsets the paint without spending a layer).
    final height = MediaQuery.sizeOf(context).height;
    final rise = height <= 0 ? 0.0 : 6 / height;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++) _branch(i, rise),
      ],
    );
  }
}
