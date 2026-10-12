import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parking_violation_app/parking_zone.dart';
import 'package:parking_violation_app/parking_zone_editor.dart';
import 'package:parking_violation_app/motion_trigger.dart';
import 'package:parking_violation_app/plate_burst.dart';

ParkingZone leftZone() => ParkingZone([
  [.05, .05],
  [.45, .05],
  [.45, .95],
  [.05, .95],
], 2);
Uint8List scene({bool inside = false, bool outside = false}) {
  final image = img.Image(width: 160, height: 80);
  for (var y = 0; y < 80; y++) {
    for (var x = 0; x < 160; x++) {
      final v = (inside && x < 72) || (outside && x > 100) ? 240 : 20;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('sharpness ranking ignores detail outside bay and duplicate frames', () {
    final frames = <Uint8List>[];
    for (final insideSharp in [false, true]) {
      final image = img.Image(width: 160, height: 80);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 160; x++) {
          final sharp = insideSharp ? x < 80 : x >= 80;
          final v = sharp ? (x % 8 < 4 ? 240 : 20) : 100;
          image.setPixelRgb(x, y, v, v, v);
        }
      }
      frames.add(Uint8List.fromList(img.encodeJpg(image)));
    }
    expect(
      rankZonePlateFrames((frames: [...frames, frames[1]], zone: leftZone())),
      [1, 0],
    );
  });
  test(
    'polygon contains bay, rejects crossing corners, tiny and invalid zones',
    () {
      final zone = leftZone();
      expect(zone.contains(.2, .5), isTrue);
      expect(zone.contains(.45, .5), isTrue);
      expect(zone.contains(.8, .5), isFalse);
      expect(ParkingZone.decode(zone.encode()).points, zone.points);
      for (final points in [
        [
          [0.0, 0.0],
          [1.0, 1.0],
          [1.0, 0.0],
          [0.0, 1.0],
        ],
        [
          [0.0, 0.0],
          [.001, 0.0],
          [.001, .001],
          [0.0, .001],
        ],
        [
          [-1.0, 0.0],
          [1.0, 0.0],
          [1.0, 1.0],
          [0.0, 1.0],
        ],
      ]) {
        expect(() => ParkingZone(points, 2), throwsFormatException);
      }
      expect(
        () => ParkingZone(leftZone().points, double.nan),
        throwsFormatException,
      );
      expect(zone.matchesAspect(4 / 3), isFalse);
    },
  );
  test('mask hides outside pixels and keeps original immutable; fails on wrong aspect', () {
    final original = scene(inside: true, outside: true);
    final copy = Uint8List.fromList(original);
    final masked = maskZoneFrames((frames: [original], zone: leftZone()));
    final image = img.decodeJpg(masked.single)!;
    expect(image.getPixel(30, 40).r, greaterThan(220));
    expect(image.getPixel(140, 40).r, lessThan(5));
    expect(original, copy);
    expect(
      () => maskZoneFrames((
        frames: [original],
        zone: ParkingZone(leftZone().points, 4 / 3),
      )),
      throwsFormatException,
    );
  });
  test(
    'motion outside bay is ignored; inside motion triggers without red strips',
    () {
      final motion = MotionTrigger(
        sampleInterval: Duration.zero,
        cooldown: Duration.zero,
      );
      expect(motion.addFrame(scene(), zone: leftZone()), isFalse);
      expect(motion.addFrame(scene(outside: true), zone: leftZone()), isFalse);
      expect(
        motion.addFrame(scene(inside: true, outside: true), zone: leftZone()),
        isTrue,
      );
    },
  );
  test('letterboxing maps image, not black margins', () {
    expect(
      containedImageRect(const Size(400, 400), 2),
      const Rect.fromLTWH(0, 100, 400, 200),
    );
    expect(
      containedImageRect(const Size(800, 200), 2),
      const Rect.fromLTWH(200, 0, 400, 200),
    );
  });
  test('zone preferences persist independently per camera, corrupt settings fail closed', () async {
    final saved = <String, String>{};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ParkingZoneStore.channel, (call) async {
      final camera = call.arguments['camera'] as String;
      if (call.method == 'save') {
        saved[camera] = call.arguments['zone'] as String;
      }
      return call.method == 'load' ? saved[camera] : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ParkingZoneStore.channel, null),
    );
    final store = ParkingZoneStore();
    await store.save('camera-a', leftZone());
    expect((await store.load('camera-a'))!.points, leftZone().points);
    expect(await store.load('camera-b'), isNull);
    saved['camera-a'] = '{}';
    expect(await store.load('camera-a'), isNull);
  });
  testWidgets(
    'four ordered taps are required; letterbox taps ignored and reset works',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ParkingZoneEditor(jpeg: scene(), aspect: 2)),
      );
      final finder = find.byKey(const ValueKey('zone-image'));
      final rect = tester.getRect(finder);
      final imageRect = containedImageRect(rect.size, 2).shift(rect.topLeft);
      await tester.tapAt(rect.topLeft + const Offset(2, 2));
      await tester.pump();
      expect(find.textContaining('0/4 corners'), findsOneWidget);
      for (final offset in [
        const Offset(.1, .1),
        const Offset(.9, .1),
        const Offset(.9, .9),
        const Offset(.1, .9),
      ]) {
        await tester.tapAt(
          imageRect.topLeft +
              Offset(offset.dx * imageRect.width, offset.dy * imageRect.height),
        );
        await tester.pump();
      }
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use whole bay'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Start again'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use whole bay'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
