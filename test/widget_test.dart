// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parking_violation_app/main.dart';
import 'package:parking_violation_app/live_camera_stream.dart';

void main() {
  for (final width in [320.0, 360.0]) {
    testWidgets('camera screen fits a $width pixel wide phone', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ParkGuardApp(autoDiscoverCamera: false));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cameras'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Live ESP32-CAM'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Analyze vehicle image'), findsOneWidget);
    });
  }

  testWidgets('analysis workspace renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ParkGuardApp(autoDiscoverCamera: false));
    expect(find.text('Analyse parking activity'), findsOneWidget);
    expect(find.text('Start analysis'), findsOneWidget);
  });

  testWidgets('camera page includes Wi-Fi configuration', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ParkGuardApp(autoDiscoverCamera: false));
    await tester.tap(find.text('Cameras'));
    await tester.pump();

    expect(find.text('Change camera Wi-Fi'), findsOneWidget);
  });

  testWidgets(
    'automatic scanning defaults on and pause survives tab switches',
    (tester) async {
      await tester.pumpWidget(const ParkGuardApp(autoDiscoverCamera: false));
      await tester.tap(find.text('Cameras'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('Results'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cameras').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one camera stream is retained while viewing Results and Analyse',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ParkGuardApp(autoDiscoverCamera: false));
      await tester.tap(find.text('Cameras'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'http://camera:81/stream');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final streams = find.byType(LiveCameraStream, skipOffstage: false);
      expect(streams, findsOneWidget);
      final original = tester.element(streams);
      await tester.tap(find.text('Results'));
      await tester.pump();
      expect(streams, findsOneWidget);
      expect(tester.element(streams), same(original));
      await tester.tap(find.text('Analyse'));
      await tester.pump();
      expect(streams, findsOneWidget);
      expect(tester.element(streams), same(original));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
