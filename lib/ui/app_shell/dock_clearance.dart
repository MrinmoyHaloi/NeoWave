import 'package:flutter/widgets.dart';

/// Bottom clearance for a [CustomScrollView] under the floating dock.
///
/// The shell publishes the dock height as bottom MediaQuery padding (the page
/// runs full height behind the blurred dock). ListView and GridView consume
/// that padding on their own; CustomScrollView does not, so each one ends its
/// slivers with this spacer.
Widget dockClearanceSliver(BuildContext context) => SliverToBoxAdapter(
      child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
    );
