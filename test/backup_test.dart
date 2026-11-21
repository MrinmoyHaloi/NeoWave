import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neowave/core/storage/app_database.dart';
import 'package:neowave/core/storage/prefs.dart';
import 'package:neowave/features/backup/backup_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'nw_sessionkey': 'SESSION',
      'nw_lastfm_api_secret': 'SECRET',
      'nw_addon_urls': 'https://example.invalid/addon',
      'ytm_cookies': 'COOKIE',
      'spotify_sp_dc': 'SPDC',
      'nw_download_dir': r'C:\Music',
      'nw_audio_device_id': 'device-1',
      'nw_username': 'someone',
      'nw_theme_mode': 'midnight',
      'nw_lyrics_text_scale': 1.2,
      'nw_amoled': true,
    });
    prefs = Prefs(await SharedPreferences.getInstance());
  });

  test('export keeps secrets and device-bound settings out of the file', () {
    final json = BackupRepository().build(
      prefs: prefs,
      db: AppDatabase.inMemory(),
      playlists: const [],
    );
    for (final leaked in [
      'SESSION',
      'SECRET',
      'example.invalid',
      'COOKIE',
      'SPDC',
      r'C:\\Music',
      'device-1',
      'someone',
    ]) {
      expect(json.contains(leaked), isFalse, reason: leaked);
    }
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['type'], backupType);
    final saved = decoded['prefs'] as Map<String, dynamic>;
    expect((saved['strings'] as Map)['nw_theme_mode'], 'midnight');
    expect((saved['doubles'] as Map)['nw_lyrics_text_scale'], 1.2);
    expect((saved['booleans'] as Map)['nw_amoled'], true);
  });

  test('import cannot write a secret or device-bound setting', () async {
    await prefs.setPortablePref('nw_sessionkey', 'ATTACKER');
    await prefs.setPortablePref('nw_download_dir', r'D:\elsewhere');
    await prefs.setPortablePref('nw_theme_mode', 'pearl');
    expect(prefs.sessionKey, 'SESSION');
    expect(prefs.downloadDir, r'C:\Music');
    expect(prefs.themeMode, 'pearl');
  });

  test('read rejects other files and newer schemas', () {
    final repo = BackupRepository();
    expect(repo.read('not json', const []), isA<BackupReadInvalid>());
    expect(repo.read('{"type":"other"}', const []), isA<BackupReadInvalid>());
    expect(
      repo.read(
        jsonEncode({'type': backupType, 'schemaVersion': backupSchema + 1}),
        const [],
      ),
      isA<BackupReadUnsupported>(),
    );
  });

  test('a backup reads back as a preview', () {
    final repo = BackupRepository();
    final json = repo.build(
      prefs: prefs,
      db: AppDatabase.inMemory(),
      playlists: const [],
    );
    final parsed = repo.read(json, const []);
    expect(parsed, isA<BackupReadOk>());
    expect((parsed as BackupReadOk).preview.playlists, isEmpty);
  });
}
