import 'package:fluent_ui/fluent_ui.dart';

import 'tokens.dart';

/// Single Fluent component system factory.
///
/// - Dark: charcoal smoked surfaces over native Mica (set in app/window.dart).
/// - Light: pearl surfaces.
/// - Accent: user accent from prefs, defaulting to neutral off-white
///   ([WaveColors.defaultAccent]). No blue accent defaults anywhere.
/// - Component radii follow [WaveRadius]: menus/popovers 7px, dialogs 10px
///   max, buttons/controls 5px. No pill buttons — pill shapes are reserved
///   for meta chips and the circular transport button.
/// - Tooltips use a 400ms wait ([WaveState.tooltipDelay]).
/// - No competing Material/ledger theming inside lib/ui/.
AccentColor _accentFrom(Color color) {
  // Build a minimal swatch around the user accent so Fluent hover/press
  // states stay coherent for any chosen color.
  final hsl = HSLColor.fromColor(color);
  final darker = hsl.withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0));
  final lighter = hsl.withLightness((hsl.lightness + 0.14).clamp(0.0, 1.0));
  return AccentColor.swatch({
    'darkest': darker.withLightness((darker.lightness - 0.1).clamp(0.0, 1.0)).toColor(),
    'darker': darker.toColor(),
    'dark': darker.withLightness((darker.lightness + 0.05).clamp(0.0, 1.0)).toColor(),
    'normal': color,
    'light': lighter.withLightness((lighter.lightness - 0.05).clamp(0.0, 1.0)).toColor(),
    'lighter': lighter.toColor(),
    'lightest': lighter.withLightness((lighter.lightness + 0.1).clamp(0.0, 1.0)).toColor(),
  });
}

/// Shape shared by every button: a borderless pill (a square icon button
/// becomes a circle).
const _controlShape = StadiumBorder();

ButtonThemeData _waveButtonTheme({required bool isLight}) {
  final ink = isLight ? Colors.black : Colors.white;
  // The muted fill every secondary control shares with the text fields.
  final muted = WidgetStateProperty.resolveWith<Color>((states) {
    if (states.isDisabled) return ink.withValues(alpha: 0.03);
    if (states.isPressed) return ink.withValues(alpha: 0.07);
    if (states.isHovered) return ink.withValues(alpha: 0.11);
    return ink.withValues(alpha: 0.06);
  });
  ButtonStyle control(ButtonStyle base) => base.copyWith(
        shape: const WidgetStatePropertyAll(_controlShape),
      );
  return ButtonThemeData(
    defaultButtonStyle: control(ButtonStyle(backgroundColor: muted)),
    filledButtonStyle: control(ButtonStyle()),
    outlinedButtonStyle: control(ButtonStyle(backgroundColor: muted)),
    iconButtonStyle: const ButtonStyle(
      shape: WidgetStatePropertyAll(_controlShape),
    ),
  );
}

/// fluent_ui's checked [ToggleButton] style uses `FilledButton.shapeBorder`
/// (a rounded rectangle), so a selected toggle would turn square next to the
/// pill buttons. [ToggleButtonThemeData.merge] replaces whole styles, so start
/// from the standard one (accent fill) and swap only the shape.
ToggleButtonThemeData _waveToggleButtonTheme(FluentThemeData base) {
  final standard = ToggleButtonThemeData.standard(base);
  const pill = ButtonStyle(shape: WidgetStatePropertyAll(_controlShape));
  return ToggleButtonThemeData(
    checkedButtonStyle: standard.checkedButtonStyle?.merge(pill) ?? pill,
    uncheckedButtonStyle: standard.uncheckedButtonStyle?.merge(pill) ?? pill,
  );
}

ContentDialogThemeData _waveDialogTheme({required Color surface}) {
  return ContentDialogThemeData(
    decoration: BoxDecoration(
      color: surface,
      borderRadius:
          BorderRadius.circular(WaveRadius.floating), // 10px max.
    ),
    actionsDecoration: BoxDecoration(
      color: surface,
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(WaveRadius.floating),
      ),
    ),
  );
}

const _waveTooltipTheme = TooltipThemeData(
  waitDuration: WaveState.tooltipDelay, // 400ms.
);

/// Resolved base-surface palette for the given theme inputs.
///
/// fluent_ui 4.17.0 removed `FluentThemeData.extensions` (and with it
/// `ThemeExtension` support), so the palette does not travel inside the
/// [FluentThemeData]. [NeoWaveApp] calls this with the same inputs and
/// publishes the result through `WaveSurfacesScope`.
WaveSurfaces waveSurfacesFor({
  required bool isLight,
  bool amoled = false,
  WaveSurfaces? custom,
}) =>
    custom ??
    ((!isLight && amoled) ? WaveSurfaces.amoled : WaveSurfaces.graphite);

/// [custom] is the user's Custom theme palette
/// ([WaveSurfaces.fromCustomBase]). When set it replaces the graphite /
/// AMOLED / pearl surfaces; [isLight] must match
/// [WaveSurfaces.isLightBase] for its base so the text tokens contrast.
FluentThemeData buildWaveFluentTheme({
  required Color accent,
  required bool isLight,
  bool amoled = false,
  WaveSurfaces? custom,
}) {
  final safeAccent =
      accent.a == 0 ? WaveColors.defaultAccent : accent;
  final accentColor = _accentFrom(safeAccent);
  final buttonTheme = _waveButtonTheme(isLight: isLight);
  // AMOLED only ever collapses the *dark* base — light ignores it.
  final surfaces = waveSurfacesFor(
    isLight: isLight,
    amoled: amoled,
    custom: custom,
  );
  if (isLight) {
    final page = custom?.background ?? WaveColors.lightBackground;
    final card = custom?.surface ?? WaveColors.lightSurface;
    final base = FluentThemeData(
      brightness: Brightness.light,
      accentColor: accentColor,
      scaffoldBackgroundColor: page,
      micaBackgroundColor: page,
      cardColor: card,
      menuColor: card,
      activeColor: WaveColors.lightTextPrimary,
      inactiveColor: WaveColors.lightTextSecondary,
      selectionColor: safeAccent.withValues(alpha: 0.25),
      visualDensity: VisualDensity.standard,
      focusTheme: const FocusThemeData(
        glowFactor: 2.0,
      ),
      buttonTheme: buttonTheme,
      dialogTheme: _waveDialogTheme(surface: card),
      tooltipTheme: _waveTooltipTheme,
    );
    return base.copyWith(toggleButtonTheme: _waveToggleButtonTheme(base));
  }
  final base = FluentThemeData(
    brightness: Brightness.dark,
    accentColor: accentColor,
    scaffoldBackgroundColor: surfaces.background,
    micaBackgroundColor: surfaces.background,
    acrylicBackgroundColor: surfaces.panelTranslucent,
    cardColor: surfaces.surface,
    menuColor: surfaces.surfaceRaised,
    activeColor: WaveColors.textPrimary,
    inactiveColor: WaveColors.textSecondary,
    selectionColor: safeAccent.withValues(alpha: 0.3),
    visualDensity: VisualDensity.standard,
    focusTheme: const FocusThemeData(
      glowFactor: 0.0,
      primaryBorder: BorderSide(width: 0),
      secondaryBorder: BorderSide(color: Colors.white, width: 1),
    ),
    buttonTheme: buttonTheme,
    dialogTheme: _waveDialogTheme(surface: surfaces.surfaceRaised),
    tooltipTheme: _waveTooltipTheme,
  );
  return base.copyWith(toggleButtonTheme: _waveToggleButtonTheme(base));
}
