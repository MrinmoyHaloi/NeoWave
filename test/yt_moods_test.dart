import 'package:flutter_test/flutter_test.dart';
import 'package:neowave/core/network/dio_factory.dart';
import 'package:neowave/core/storage/secure_store.dart';
import 'package:neowave/features/home/home_snapshot.dart';
import 'package:neowave/features/innertube/innertube_api.dart';

Map<String, dynamic> _button(String title, String? params, [int? color]) => {
      'musicNavigationButtonRenderer': {
        'buttonText': {
          'runs': [
            {'text': title},
          ],
        },
        if (color != null) 'solid': {'leftStripeColor': color},
        'clickCommand': {
          'browseEndpoint': {
            'browseId': 'FEmusic_moods_and_genres_category',
            'params': ?params,
          },
        },
      },
    };

Map<String, dynamic> _grid(String title, List<Map<String, dynamic>> items) => {
      'itemSectionRenderer': {
        'contents': [
          {
            'gridRenderer': {
              'header': {
                'gridHeaderRenderer': {
                  'title': {
                    'runs': [
                      {'text': title},
                    ],
                  },
                },
              },
              'items': items,
            },
          },
        ],
      },
    };

Map<String, dynamic> _root(List<Map<String, dynamic>> sections) => {
      'contents': {
        'singleColumnBrowseResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {'contents': sections},
                },
              },
            },
          ],
        },
      },
    };

void main() {
  final tube = InnerTubeMusicApi(DioFactory.create(), SecureStore());

  group('parseMoodButtons', () {
    test('picks the moods grid, skips genres, dedupes and drops bad rows', () {
      final root = _root([
        _grid('Genres', [_button('Rock', 'g1')]),
        _grid('Moods & moments', [
          _button('Relax', 'p1', 0xFF112233),
          _button('Relax again', 'p1'),
          _button('Workout', 'p2'),
          _button('', 'p3'),
          _button('No params', null),
        ]),
      ]);
      final moods = tube.parseMoodButtons(root);
      expect(moods.map((m) => m.title), ['Relax', 'Workout']);
      expect(moods.first.params, 'p1');
      expect(moods.first.color, 0xFF112233);
    });

    test('falls back to the first grid when none says mood', () {
      final root = _root([
        _grid('Browse', [_button('Chill', 'c1')]),
      ]);
      expect(tube.parseMoodButtons(root).single.title, 'Chill');
    });

    test('malformed payloads yield nothing', () {
      expect(tube.parseMoodButtons(const {}), isEmpty);
      expect(tube.parseMoodButtons(_root([])), isEmpty);
    });
  });

  group('snapshot codecs', () {
    test('moods round trip', () {
      const moods = [YtMood(title: 'Relax', params: 'p1', color: 5)];
      final back = moodsSnapshotCodec.decode(moodsSnapshotCodec.encode(moods));
      expect(back!.single.title, 'Relax');
      expect(back.single.params, 'p1');
      expect(back.single.color, 5);
    });

    test('entities round trip', () {
      const list = [
        YouTubeMusicEntity(
          kind: YouTubeEntityKind.playlist,
          name: 'Chill Hits',
          browseId: 'VLPL1',
        ),
      ];
      final back =
          entitiesSnapshotCodec.decode(entitiesSnapshotCodec.encode(list));
      expect(back!.single.name, 'Chill Hits');
      expect(back.single.browseId, 'VLPL1');
    });
  });
}
