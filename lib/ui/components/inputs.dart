import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart' show waveIsDark;

/// The one text-field look: a muted, borderless pill.
///
/// Fluent's [TextBox] hard-codes a 4px corner, a stock fill and a bottom bar
/// (1.25px idle, 2px accent when focused), and exposes no theme hook for any of
/// them. Everything is overridden per field, so a field takes BOTH
/// [waveInputDecoration] (the fill, brighter on hover and focus) and
/// [waveInputForegroundDecoration] (swaps the bottom bar for a transparent
/// border) and should set `textAlignVertical: TextAlignVertical.center`.
WidgetStateProperty<BoxDecoration> waveInputDecoration(
  BuildContext context, {
  double radius = 15,
}) {
  final base = waveIsDark(context) ? Colors.white : Colors.black;
  return WidgetStateProperty.resolveWith((states) {
    final alpha = states.isFocused
        ? 0.09
        : states.isHovered
            ? 0.07
            : 0.045;
    return BoxDecoration(
      color: base.withValues(alpha: alpha),
      borderRadius: BorderRadius.circular(radius),
    );
  });
}

/// Foreground half of the pill. Replaces the stock bottom bar with a clear
/// border, which turns into a soft accent ring while the field has focus so
/// keyboard users always see where they are.
WidgetStateProperty<BoxDecoration> waveInputForegroundDecoration(
  BuildContext context, {
  double radius = 15,
}) {
  final accent = FluentTheme.of(context).accentColor.defaultBrushFor(
        FluentTheme.of(context).brightness,
      );
  return WidgetStateProperty.resolveWith((states) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: states.isFocused
            ? accent.withValues(alpha: 0.7)
            : Colors.transparent,
        width: states.isFocused ? 1.5 : 0,
      ),
    );
  });
}
