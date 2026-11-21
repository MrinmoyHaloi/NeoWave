import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Semantic Fluent surfaces: single source of truth for every page.
///
/// Read surfaces through [NwSurfaces] (context-aware) or the raw [NwColors]
/// constants below; do not scatter hex literals in pages.
///
/// Mapping to the Wave tokens (`lib/ui/theme/tokens.dart`):
/// - surfaceBase: scaffold / Mica base
/// - surfaceLayer1/2: content layering (cards stay flat, layers differ)
/// - surfaceMica: native Mica base (window.dart paints this)
/// - surfaceAcrylic: title chrome / suggestion flyout base
/// - surfaceHaze: Haze L1/L2 tonal wash (see nw_materials.dart)
/// - surfaceElevated / surfacePlayer: player dock and raised controls
/// - surfaceFlyout: MenuFlyout / ContentDialog / popover (Haze L3)
///
/// Interaction tokens mirror WinUI: hover 7% wash, pressed 12%, selected
/// accent wash, 2px focus ring ([waveFocusRing]).
class NwColors {
  NwColors._();

  // -- Dark (graphite, zero navy) -----------------------------------------
  static const surfaceBase = WaveColors.background; // #0E0E0E
  static const surfaceBaseDeep = WaveColors.backgroundDeep; // #0A0A0A
  static const surfaceLayer1 = WaveColors.surface; // #161616
  static const surfaceLayer2 = WaveColors.surfaceRaised; // #1E1E1E
  static const surfaceMica = WaveColors.background;
  static const surfaceAcrylic = WaveColors.panelTranslucent; // 0xE6161616
  static const surfaceHaze = WaveColors.panelTranslucent;
  static const surfaceElevated = WaveColors.surfaceOverlay; // #262626
  static const surfaceFlyout = WaveColors.surfaceRaised; // #1E1E1E
  static const surfacePlayer = WaveColors.dockTranslucent; // 0xF2141414

  static const textPrimary = WaveColors.textPrimary;
  static const textSecondary = WaveColors.textSecondary;
  static const textTertiary = WaveColors.textTertiary;

  static const divider = WaveColors.outlineSoft; // #1F1F1F hairline
  static const dividerStrong = WaveColors.outline; // #2B2B2B

  static const accent = WaveColors.defaultAccent; // off-white neutral
  static const success = WaveColors.success;
  static const warn = WaveColors.warn;
  static const danger = WaveColors.danger;

  // -- Light (neutral off-white, not beige / not pure white) ---------------
  static const lightSurfaceBase = WaveColors.lightBackground; // #F3F3F3
  static const lightSurfaceNav = WaveColors.lightNavBackground; // #ECECEC
  static const lightSurfaceLayer1 = WaveColors.lightContent; // #F9F9F9
  static const lightSurfaceLayer2 = WaveColors.lightSurface; // #FFFFFF
  static const lightSurfaceFlyout = WaveColors.lightSurface;
  static const lightSurfacePlayer = WaveColors.lightSurface;
  static const lightTextPrimary = WaveColors.lightTextPrimary;
  static const lightTextSecondary = WaveColors.lightTextSecondary;
  static const lightTextTertiary = WaveColors.lightTextTertiary;
  // Black 10%, matching `waveDivider`: a fixed grey could only ever read on
  // the white cards or on the #F3F3F3 page, never on both.
  static const lightDivider = Color(0x1A000000);
  static const lightDividerStrong = WaveColors.lightOutline;
}

/// Context-aware surface resolution (dark ↔ light).
class NwSurfaces {
  NwSurfaces._();

  static bool isDark(BuildContext context) => waveIsDark(context);

  static Color base(BuildContext context) =>
      isDark(context) ? NwColors.surfaceBase : NwColors.lightSurfaceBase;

  static Color layer1(BuildContext context) => isDark(context)
      ? NwColors.surfaceLayer1
      : NwColors.lightSurfaceLayer1;

  static Color layer2(BuildContext context) => isDark(context)
      ? NwColors.surfaceLayer2
      : NwColors.lightSurfaceLayer2;

  static Color flyout(BuildContext context) => isDark(context)
      ? NwColors.surfaceFlyout
      : NwColors.lightSurfaceFlyout;

  static Color player(BuildContext context) => isDark(context)
      ? NwColors.surfacePlayer
      : NwColors.lightSurfacePlayer.withValues(alpha: 0.97);

  static Color textPrimary(BuildContext context) => waveTextPrimary(context);
  static Color textSecondary(BuildContext context) =>
      waveTextSecondary(context);
  static Color textTertiary(BuildContext context) => waveTextTertiary(context);
  static Color divider(BuildContext context) => waveDivider(context);

  /// Artwork accent: runtime tint applied sparingly (Now Playing wash,
  /// hero wash ≤12%). Base surfaces stay neutral — artwork adds
  /// atmosphere, never floods the app.
  static Color artworkAccent(BuildContext context, Color? tint) =>
      tint ?? waveAccent(context);
}
