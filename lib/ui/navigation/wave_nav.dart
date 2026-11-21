import 'package:fluent_ui/fluent_ui.dart';
import 'package:go_router/go_router.dart';

import 'flight.dart';

/// Opens [location] as a page *stacked* on top of the current one.
///
/// `context.go` rewrites the branch's page list, so the destination mounts
/// already complete with no transition and nothing underneath to close back
/// over. Pushing keeps the source on the stack, which lets the anchored
/// entrance in `lib/app/router.dart` play in (growing out of the pressed
/// point) and reverse on the way out (see `route_origin.dart`). The shell's
/// back button and Esc both `pop` before replaying location history.
///
/// Use it for anything opened *from* a page: an album, artist, YouTube
/// playlist, Now Playing. Rail destinations and command-palette jumps stay
/// `go`/`goBranch`, which swap the tab rather than stack on it.
void waveOpen(BuildContext context, String location) {
  // Record where this came from before pushing: the detail header replays the
  // cover flight out of the pressed card. See `flight.dart`.
  WaveFlight.arm(context, location);
  context.push(location);
}

/// `/album/<id>` carrying the metadata the pressed card already had.
///
/// `browseAlbum` is a round trip, so the album page cannot draw its own header
/// until it answers. Without a seed the route entrance plays over a spinner
/// and the cover/title pop in a beat later — read as "the album page never
/// faded in, it takes time to load". Passing name/artist/cover in the query
/// string (the same trick `/ytplaylist/:id` uses for `title`/`art`) lets the
/// destination render its real header on the first frame, which is what the
/// entrance then animates; the track table fades in underneath when the
/// browse lands. Every field is optional — a caller without the data simply
/// gets the loading skeleton.
String waveAlbumLocation({
  required String browseId,
  String title = '',
  String artist = '',
  String artworkUrl = '',
}) {
  final query = <String>[
    if (title.isNotEmpty) 'title=${Uri.encodeQueryComponent(title)}',
    if (artist.isNotEmpty) 'artist=${Uri.encodeQueryComponent(artist)}',
    if (artworkUrl.isNotEmpty) 'art=${Uri.encodeQueryComponent(artworkUrl)}',
  ];
  final path = '/album/${Uri.encodeComponent(browseId)}';
  return query.isEmpty ? path : '$path?${query.join('&')}';
}
