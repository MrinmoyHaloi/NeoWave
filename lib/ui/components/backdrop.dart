import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Shell root surface: the fluent [Mica] background plus a barely-there
/// diagonal wash painted over it.
///
/// The wash is [waveBackdropGradient] — a ~2% lightness drift off
/// [waveBackground], so Custom / Midnight / Pearl / AMOLED each keep their
/// own hue and every surface painted above it keeps its contrast ratio. It
/// exists only to stop the pages from sitting on one flat fill.
///
/// [StackFit.passthrough] keeps the previous constraints (Mica → child was a
/// direct hand-off), and the gradient layer ignores pointers, so nothing about
/// hit-testing or layout changes.
class WaveShellBackdrop extends StatelessWidget {
  const WaveShellBackdrop({
    super.key,
    required this.backgroundColor,
    required this.child,
  });

  /// Passed straight to [Mica]; also the midpoint of the gradient.
  final Color backgroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Mica(
      backgroundColor: backgroundColor,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: waveBackdropGradient(context),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
