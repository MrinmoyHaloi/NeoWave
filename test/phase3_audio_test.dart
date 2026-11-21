import 'package:flutter_test/flutter_test.dart';
import 'package:neowave/core/audio/stream_models.dart';
import 'package:neowave/core/storage/prefs.dart';
import 'package:neowave/features/player/loudness.dart';

void main() {
  test('data saver is a persisted quality with a short label', () {
    expect(Prefs.allowedQualities, contains(AudioQualityTiers.dataSaver));
    expect(
      AudioQualityTiers.label(AudioQualityTiers.dataSaver),
      'Data saver',
    );
  });

  test('loudness uses tags when present and does not invent a scan', () {
    expect(
      LoudnessMath.tagGainDb(mode: 'track', trackGainDb: -6, albumGainDb: -3),
      -6,
    );
    expect(
      LoudnessMath.tagGainDb(mode: 'album', trackGainDb: -6, albumGainDb: -3),
      -3,
    );
    expect(
      LoudnessMath.tagGainDb(mode: 'album', trackGainDb: -6),
      -6,
    );
    expect(LoudnessMath.tagGainDb(mode: 'track'), isNull);
    expect(LoudnessMath.parseDb('-7.5 dB'), -7.5);
    expect(LoudnessMath.preampDb, 4);
    expect(LoudnessMath.fallbackDb, -3);
    expect(LoudnessMath.sameAlbumGain(-5.0, -5.2), isTrue);
    expect(LoudnessMath.sameAlbumGain(-5.0, -8.0), isFalse);
    expect(
      LoudnessMath.settingsSubtitle('track'),
      contains('not a loudness scan'),
    );
  });

}
