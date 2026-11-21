import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../ui/theme/tokens.dart';

/// ONE reusable Fluent scrollbar treatment.
///
/// - thin (6px idle, 8px hover), unobtrusive, fades when idle
/// - larger hit area than visible thumb (Fluent handles this)
/// - no huge track, no browser appearance
/// - vertical only for page regions; horizontal carousels hide bars and
///   rely on wheel/trackpad/drag + subtle edge affordance
/// - reserves space so durations/actions/lyrics never sit underneath
class WaveThinScrollbar extends StatelessWidget {
  final Widget child;
  final ScrollController? controller;
  final bool thumbVisible;
  const WaveThinScrollbar({
    super.key,
    required this.child,
    this.controller,
    this.thumbVisible = false,
  });

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      controller: controller,
      thumbVisibility: thumbVisible,
      thickness: 6,
      radius: const Radius.circular(WaveRadius.tiny),
      minThumbLength: 40,
      fadeDuration: WaveMotion.normal,
      timeToFade: const Duration(milliseconds: 800),
      pressDuration: Duration.zero,
      child: child,
    );
  }
}

/// Global scroll behaviour: thin Fluent bars, smooth inertia scroll physics,
/// and support for mouse and trackpad dragging. Horizontal strips scroll via wheel/
/// trackpad/drag; the bar only appears while interacting.
class WaveScrollBehavior extends FluentScrollBehavior {
  /// [hideCarouselBars] drops the horizontal bar but keeps wheel smoothing,
  /// which `ScrollBehavior.copyWith(scrollbars: false)` would also remove.
  const WaveScrollBehavior({this.hideCarouselBars = false});

  final bool hideCarouselBars;

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    // Mouse is a drag device (carousels), so inside a text field the
    // internal scrollable would grab the press and pan the text instead of
    // extending the selection. Caret/selection auto-scroll is programmatic
    // and unaffected by this.
    if (context.findAncestorWidgetOfExactType<EditableText>() != null) {
      return const NeverScrollableScrollPhysics();
    }
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }

  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    Widget scrollbar;
    // Horizontal carousels: deliberate scroll, no permanent bar.
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      scrollbar = hideCarouselBars
          ? child
          : RawScrollbar(
              controller: details.controller,
              thumbVisibility: false,
              thickness: 4,
              radius: const Radius.circular(WaveRadius.tiny),
              fadeDuration: WaveMotion.fast,
              timeToFade: const Duration(milliseconds: 600),
              child: child,
            );
    } else {
      scrollbar = RawScrollbar(
        controller: details.controller,
        thumbVisibility: false,
        thickness: 6,
        radius: const Radius.circular(WaveRadius.tiny),
        minThumbLength: 40,
        fadeDuration: WaveMotion.normal,
        timeToFade: const Duration(milliseconds: 800),
        child: child,
      );
    }
    return WaveSmoothScroll(
      controller: details.controller,
      direction: details.direction,
      child: scrollbar,
    );
  }
}

/// Browser-style wheel scrolling. Wheel notches only move a target offset;
/// every frame the position closes a fixed fraction of the remaining gap
/// (exponential smoothing), so velocity is continuous no matter how fast
/// notches arrive.
///
/// Flutter's own `Scrollable` registers its (jump-to-offset) wheel handler
/// from a Listener that sits INSIDE the widget returned by `buildScrollbar`,
/// and the pointer-signal resolver is first-come-first-served. A plain
/// Listener here is therefore always second and never won. [_WheelFirst]
/// puts this widget at the front of the hit-test path instead.
class WaveSmoothScroll extends StatefulWidget {
  final Widget child;

  /// Kept for call-site compatibility; the owning scrollable is found from
  /// the tree, because most scroll views here have no explicit controller.
  final ScrollController? controller;
  final AxisDirection direction;

  /// Time constant of the glide. Short on purpose: a notch should land in
  /// roughly 130ms, smooth but never floaty.
  final Duration smoothing;

  const WaveSmoothScroll({
    super.key,
    required this.child,
    this.controller,
    this.direction = AxisDirection.down,
    this.smoothing = const Duration(milliseconds: 55),
  });

  @override
  State<WaveSmoothScroll> createState() => _WaveSmoothScrollState();
}

class _WaveSmoothScrollState extends State<WaveSmoothScroll>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  static const double _minSpeed = 1.0; // px per ms, the glide never drops below
  // Scroll boost: notches closer than this chain into a streak, each one
  // adding _boostStep to the multiplier, capped at _boostMax.
  static const double _boostWindowMs = 140;
  static const double _boostStep = 0.3;
  static const double _boostMax = 3.0;
  int _streak = 0;
  Duration _lastNotchAt = Duration.zero;
  double? _targetPixels;
  Duration _lastTick = Duration.zero;
  ScrollPosition? _activePosition;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool get _isVertical =>
      widget.direction == AxisDirection.down ||
      widget.direction == AxisDirection.up;

  /// The scroll view this wrapper was built by. `Scrollable.maybeOf` would
  /// return the *outer* one here: its scope widget lives below this one.
  ScrollPosition? get _position {
    final state = context.findAncestorStateOfType<ScrollableState>();
    if (state == null) return null;
    try {
      final p = state.position;
      return p.hasPixels ? p : null;
    } catch (_) {
      return null;
    }
  }

  void _onTick(Duration elapsed) {
    final position = _activePosition;
    final target = _targetPixels;
    if (position == null || !position.hasPixels || target == null) {
      _stopGliding();
      return;
    }
    // Frame-rate independent: the same glide at 60, 120 or 144 Hz.
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final tau = widget.smoothing.inMicroseconds / 1000.0;
    final k = tau <= 0 ? 1.0 : 1.0 - math.exp(-dt.clamp(0.0, 64.0) / tau);

    final current = position.pixels;
    final gap = target - current;
    // Pure exponential smoothing has a long tail that reads as the page
    // slowing down and floating to a stop. A speed floor keeps it moving
    // at a steady pace until it lands, so a notch is quick and ends cleanly.
    final floor = _minSpeed * dt.clamp(0.0, 64.0);
    final step = gap.abs() <= floor
        ? gap
        : gap.sign * math.max(gap.abs() * k, floor);
    final next = (current + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - next).abs() < 0.4) {
      position.jumpTo(target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ));
      _stopGliding();
      return;
    }
    position.jumpTo(next);
  }

  void _stopGliding() {
    if (_ticker.isActive) _ticker.stop();
    _targetPixels = null;
    _activePosition = null;
    _lastTick = Duration.zero;
  }

  double _delta(PointerScrollEvent e) =>
      _isVertical ? e.scrollDelta.dy : e.scrollDelta.dx;

  /// Could THIS scrollable move for this wheel event? A scrollable that
  /// cannot (wrong axis, nothing to scroll, pinned at that edge) must not
  /// claim it, so the next one out gets the wheel.
  bool _canClaim(PointerScrollEvent event) {
    if (!mounted || event.kind != PointerDeviceKind.mouse) return false;
    final delta = _delta(event);
    if (delta == 0) return false;
    final position = _position;
    if (position == null) return false;
    if (position.maxScrollExtent <= position.minScrollExtent) return false;
    final atStart = position.pixels <= position.minScrollExtent;
    final atEnd = position.pixels >= position.maxScrollExtent;
    if ((delta < 0 && atStart) || (delta > 0 && atEnd)) {
      return _targetPixels != null;
    }
    return true;
  }

  void _onWheel(PointerScrollEvent event) {
    if (!_canClaim(event)) return;

    // This wrapper is first in the hit-test path, i.e. OUTERMOST first. The
    // innermost scrollable that can move must win (a list inside a page), so
    // defer unless this is that one.
    final hit = HitTestResult();
    WidgetsBinding.instance
        .hitTestInView(hit, event.position, event.viewId);
    for (final entry in hit.path.toList().reversed) {
      final target = entry.target;
      if (target is _RenderWheelFirst) {
        final other = target.scroller;
        if (identical(other, this)) break;
        if (other._canClaim(event)) return;
      }
    }

    // Register with the resolver so Flutter's default stepped pointerScroll
    // does NOT fire for this event.
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!mounted) return;
      final scrollEvent = resolved as PointerScrollEvent;
      final position = _position;
      final d = _delta(scrollEvent);
      if (position == null || d == 0) return;

      // Notches accumulate onto the standing target, so a fast spin keeps
      // extending one continuous glide instead of restarting it. Notches
      // that follow each other closely are boosted, as in browsers: a single
      // click moves one notch, a sustained spin covers real distance.
      final gapMs = _streak == 0
          ? double.infinity
          : (scrollEvent.timeStamp - _lastNotchAt).inMicroseconds / 1000.0;
      _streak = gapMs <= _boostWindowMs ? _streak + 1 : 1;
      _lastNotchAt = scrollEvent.timeStamp;
      final boost = math.min(1.0 + (_streak - 1) * _boostStep, _boostMax);
      final base = _targetPixels ?? position.pixels;
      _targetPixels = (base + d * boost).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _activePosition = position;
      if (!_ticker.isActive) {
        _lastTick = Duration.zero;
        _ticker.start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _WheelFirst(owner: this, child: widget.child);
  }
}

class _WheelFirst extends SingleChildRenderObjectWidget {
  final _WaveSmoothScrollState owner;
  const _WheelFirst({required this.owner, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWheelFirst(owner);

  @override
  void updateRenderObject(
          BuildContext context, _RenderWheelFirst renderObject) =>
      renderObject.scroller = owner;
}

/// Adds itself to the hit-test path BEFORE its descendants (the usual order
/// is the reverse), so its pointer events are delivered ahead of the
/// `Scrollable`'s own Listener below it.
class _RenderWheelFirst extends RenderProxyBox {
  _RenderWheelFirst(this.scroller);
  _WaveSmoothScrollState scroller;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    child?.hitTest(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerScrollEvent) {
      scroller._onWheel(event);
    } else if (event is PointerDownEvent) {
      // Touching or dragging cancels any glide in progress.
      scroller._stopGliding();
    }
  }
}
