import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';
import 'nw_colors.dart';

/// Haze material system: depth without blur soup.
///
/// - L0 crisp: track tables, dense library, album grids. No blur, opaque.
/// - L1 subtle tonal: navigation pane, title chrome, player dock.
///   Translucent wash + 12px blur; callers opt in via [enableBlur] only where
///   something sits behind the surface.
/// - L2 apparent: queue panel, lyrics controls, floating clusters. 20px blur
///   in a bounded 320-380px region; rows stay crisp.
/// - L3 transient: menus, flyouts, popovers, dialogs. 28px blur, small
///   radius, strong shadow. Never full-screen.
///
/// Performance: bound blur regions, never blur continuously changing content
/// (progress, lyrics ticks), prefer static tonal materials, and keep artwork
/// tint at <=12% alpha, low saturation, cached per media ID.
enum NwHazeLevel { l0, l1, l2, l3 }

/// Per-level blur + tint configuration.
class NwHazeSpec {
  final double blurSigma;
  final double darkAlpha;
  final double lightAlpha;
  final double tintCap;
  const NwHazeSpec({
    required this.blurSigma,
    required this.darkAlpha,
    required this.lightAlpha,
    this.tintCap = 0.12,
  });
}

const lwHazeSpecs = <NwHazeLevel, NwHazeSpec>{
  NwHazeLevel.l0: NwHazeSpec(blurSigma: 0, darkAlpha: 1.0, lightAlpha: 1.0),
  NwHazeLevel.l1: NwHazeSpec(blurSigma: 12, darkAlpha: 0.88, lightAlpha: 0.90),
  NwHazeLevel.l2: NwHazeSpec(blurSigma: 20, darkAlpha: 0.82, lightAlpha: 0.88),
  NwHazeLevel.l3: NwHazeSpec(blurSigma: 28, darkAlpha: 0.86, lightAlpha: 0.94),
};

/// Haze material container.
///
/// - L0: plain opaque surface (no filter — cheapest, used for lists).
/// - L1–L3: tonal wash + optional bounded [BackdropFilter]. Set
///   [enableBlur] false to force the static tonal fallback (low-end /
///   `reduceTransparency` / Haze=Solid setting).
/// - [artworkTint]: optional cached palette color; mixed at ≤12% so the
///   base stays neutral.
/// - [borderRadius]/[border]/[shadow] follow [NwElevation]-style values.
class NwHaze extends StatelessWidget {
  final NwHazeLevel level;
  final Widget child;
  final Color? base;
  final Color? artworkTint;
  final BorderRadiusGeometry borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;
  final bool enableBlur;
  final Alignment alignment;

  /// Absolute fill alpha, overriding the level's spec alpha.
  ///
  /// Only applied while the filter is actually on: a surface thinned to 40%
  /// with nothing to frost would be unreadable, so Solid / reduced-transparency
  /// falls back to the level's tonal alpha. Used by the surfaces that have to
  /// match a hand-tuned frost recipe (the expanded rail wearing the lyrics
  /// drawer's tint) rather than a spec level.
  final double? fillAlpha;

  const NwHaze({
    super.key,
    required this.level,
    required this.child,
    this.base,
    this.artworkTint,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.shadow,
    this.enableBlur = true,
    this.alignment = Alignment.center,
    this.fillAlpha,
  });

  /// L1 chrome (rail / title / dock).
  const NwHaze.chrome({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
    this.fillAlpha,
  })  : level = NwHazeLevel.l1,
        borderRadius = BorderRadius.zero,
        alignment = Alignment.center;

  /// L2 panel (queue / suggestion / floating cluster).
  const NwHaze.panel({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
    this.fillAlpha,
  })  : level = NwHazeLevel.l2,
        borderRadius = BorderRadius.zero,
        alignment = Alignment.center;

  /// L3 flyout (menu / dialog / popover).
  const NwHaze.flyout({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
    this.fillAlpha,
  })  : level = NwHazeLevel.l3,
        borderRadius = const BorderRadius.all(Radius.circular(WaveRadius.menu)),
        alignment = Alignment.center;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final spec = lwHazeSpecs[level]!;
    // Default fill follows the active palette (AMOLED / Custom); Pearl
    // keeps its #F9F9F9 content tone.
    final surfaces = waveSurfaces(context);
    final resolvedBase = base ??
        (surfaces.isCustom || dark
            ? surfaces.surface
            : NwColors.lightSurfaceLayer1);
    final reduceT =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    final useBlur = enableBlur &&
        !reduceT &&
        spec.blurSigma > 0 &&
        level != NwHazeLevel.l0;
    final specAlpha = dark ? spec.darkAlpha : spec.lightAlpha;
    final alpha = !useBlur && level == NwHazeLevel.l1
        ? (dark ? 0.94 : 0.96)
        : (useBlur ? (fillAlpha ?? specAlpha) : specAlpha);
    var fill = resolvedBase.withValues(alpha: alpha);
    if (artworkTint != null && level != NwHazeLevel.l0) {
      // Low-saturation atmosphere: mix tint at ≤12%, never flood.
      final tint = artworkTint!.withValues(alpha: spec.tintCap);
      fill = Color.alphaBlend(tint, fill);
    }
    final content = Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: borderRadius,
        border: border,
        boxShadow: shadow,
      ),
      child: child,
    );
    if (!useBlur) return content;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius is BorderRadius
            ? borderRadius as BorderRadius
            : BorderRadius.zero,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: spec.blurSigma,
            sigmaY: spec.blurSigma,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Ambient artwork wash (Now Playing / hero backdrops).
///
/// Static radial glow, no animation, no fullscreen blur. Saturation is
/// kept low by blending the seed at 18–28% over the neutral base.
class NwAmbientWash extends StatelessWidget {
  final Color? seed;
  final double height;
  final Alignment center;
  const NwAmbientWash({
    super.key,
    required this.seed,
    this.height = 320,
    this.center = const Alignment(-0.7, -0.6),
  });

  @override
  Widget build(BuildContext context) {
    if (seed == null) return const SizedBox.shrink();
    final dark = waveIsDark(context);
    final reduceT =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (reduceT) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: center,
            radius: 1.1,
            colors: [
              seed!.withValues(alpha: dark ? 0.28 : 0.18),
              seed!.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}
