import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Screen-reader plumbing shared by the whole app.
///
/// Flutter only builds its semantics tree while the engine reports an
/// assistive technology. On Windows that report is driven by UIA queries and
/// can drop while the window is in the background (minimized, tray-hidden,
/// or just deactivated by Alt+Tab), after which NVDA finds an empty tree on
/// return and the app reads as "completely unusable" until restart. Holding
/// a permanent [SemanticsHandle] keeps the tree built for the whole session,
/// so whatever the screen reader asks for after a return is already there.
///
/// The second half is focus: returning to the window must land keyboard
/// focus on a real control, otherwise NVDA announces only the window title
/// and Tab starts from nowhere. [AppFocusMemory] remembers the last control
/// focused from the keyboard and puts focus back on it every time the window
/// is activated again. With nothing remembered, focus rests on the shell.
class AppAccessibility {
  AppAccessibility._();

  static SemanticsHandle? _handle;

  /// Call once after `WidgetsFlutterBinding.ensureInitialized()`.
  static void enable() {
    _handle ??= SemanticsBinding.instance.ensureSemantics();
    AppFocusMemory.instance.start();
  }

  /// Speaks [message] through the active screen reader without moving focus.
  static void announce(BuildContext context, String message) {
    if (message.isEmpty) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
  }
}

/// Remembers the last control focused from the keyboard, so window
/// re-activation can restore it. Focus that a mouse click moved is not
/// remembered: restoring a clicked button would let Space press it.
class AppFocusMemory {
  AppFocusMemory._();
  static final AppFocusMemory instance = AppFocusMemory._();

  bool _started = false;
  FocusNode? _last;
  bool _restoreQueued = false;
  // Which input moved focus last. A key press sets it, a pointer press
  // clears it; focus changes are only remembered while it is set.
  bool _keyboardInput = false;

  void start() {
    if (_started) return;
    _started = true;
    FocusManager.instance.addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _keyboardInput = true;
    return false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _keyboardInput = false;
  }

  /// Drops the remembered control: the next window return leaves focus on
  /// the shell. Escape calls this.
  void forget() {
    _last = null;
  }

  void _onFocusChanged() {
    final node = FocusManager.instance.primaryFocus;
    if (_keyboardInput && _isControl(node)) _last = node;
  }

  /// A node a person can actually act on: attached, focusable, and not just a
  /// scope (scopes hold focus for their children, nothing to announce).
  static bool _isControl(FocusNode? node) =>
      node != null &&
      node is! FocusScopeNode &&
      node.context != null &&
      // Still in the focus tree: a node swapped out of a reused widget keeps
      // its old context but has no parent, and focusing it does nothing.
      node.parent != null &&
      node.canRequestFocus &&
      !node.skipTraversal;

  /// Puts keyboard focus back on a real control after the window returns.
  ///
  /// Focus is cleared and re-applied on the next frame even when the node
  /// still holds it: the screen reader only speaks on a focus *change*, so
  /// re-requesting an already-focused node would leave it silent.
  void restore() {
    if (_restoreQueued) return;
    _restoreQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _restoreQueued = false;
      final target = _isControl(_last) ? _last! : null;
      if (target != null) {
        if (target.hasPrimaryFocus) {
          target.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (_isControl(target)) target.requestFocus();
          });
        } else {
          target.requestFocus();
        }
        return;
      }
      _parkFocus();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Node that owns no controls (the app shell's). Focus rests there when no
  /// keyboard-focused control is remembered, so nothing is pressed by Space
  /// and nothing is focused without the user asking for it. Screen readers
  /// announce the window title, and Tab starts at the first control.
  FocusNode? parkNode;

  /// Moves focus off a control the mouse focused before the window returned.
  void _parkFocus() {
    final park = parkNode;
    if (park == null || !_isControl(FocusManager.instance.primaryFocus)) return;
    park.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
  }
}
