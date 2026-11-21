import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neowave/design_system/fluent/nw_scrollbar.dart';

Widget _app(Widget child) => FluentApp(
      scrollBehavior: const WaveScrollBehavior(),
      home: SizedBox(width: 400, height: 400, child: child),
    );

Future<void> _wheel(WidgetTester tester, Offset at, double dy,
    {Duration time = Duration.zero}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy), timeStamp: time));
}

void main() {
  testWidgets('one wheel notch glides instead of jumping (no controller)',
      (tester) async {
    await tester.pumpWidget(_app(ListView.builder(
      itemCount: 100,
      itemExtent: 50,
      itemBuilder: (_, i) => Text('row $i'),
    )));
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);

    await _wheel(tester, const Offset(200, 200), 100);
    // Frame 1 starts the ticker, frame 2 is the first step of the glide.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final mid = scrollable.position.pixels;
    expect(mid, greaterThan(0), reason: 'should have started moving');
    expect(mid, lessThan(100), reason: 'must not jump the whole notch');

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrollable.position.pixels, closeTo(100, 0.5));
  });

  testWidgets('a quick streak of notches is boosted into one glide',
      (tester) async {
    await tester.pumpWidget(_app(ListView.builder(
      itemCount: 100,
      itemExtent: 50,
      itemBuilder: (_, i) => Text('row $i'),
    )));
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    for (var i = 0; i < 3; i++) {
      await _wheel(tester, const Offset(200, 200), 100,
          time: Duration(milliseconds: i * 16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 100 + 100*1.3 + 100*1.6: later notches of a streak travel further.
    expect(scrollable.position.pixels, closeTo(390, 0.5));
  });

  testWidgets('notches separated by a pause are not boosted', (tester) async {
    await tester.pumpWidget(_app(ListView.builder(
      itemCount: 100,
      itemExtent: 50,
      itemBuilder: (_, i) => Text('row $i'),
    )));
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    for (var i = 0; i < 3; i++) {
      await _wheel(tester, const Offset(200, 200), 100,
          time: Duration(milliseconds: i * 600));
      for (var f = 0; f < 40; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    expect(scrollable.position.pixels, closeTo(300, 0.5));
  });

  testWidgets('a list inside a page scrolls first, then the page takes over',
      (tester) async {
    final inner = ScrollController();
    final outer = ScrollController();
    await tester.pumpWidget(_app(ListView(
      controller: outer,
      children: [
        SizedBox(
          height: 200,
          child: ListView.builder(
            controller: inner,
            itemCount: 20,
            itemExtent: 50,
            itemBuilder: (_, i) => Text('in $i'),
          ),
        ),
        const SizedBox(height: 2000),
      ],
    )));

    Future<void> settle() async {
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await _wheel(tester, const Offset(200, 100), 100);
    await settle();
    expect(inner.offset, closeTo(100, 0.5));
    expect(outer.offset, 0);

    // Pinned at the inner list's end: the page behind it gets the wheel.
    inner.jumpTo(inner.position.maxScrollExtent);
    await tester.pump();
    await _wheel(tester, const Offset(200, 100), 100);
    await settle();
    expect(outer.offset, closeTo(100, 0.5));
  });
}
