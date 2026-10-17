import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parking_violation_app/bay_buzzer.dart';
import 'package:parking_violation_app/image_parking_analyzer.dart';
import 'package:parking_violation_app/plate_ocr.dart';

ImageParkingObservation vehicle(
  String position, {
  String plate = 'KA58W0344',
}) => ImageParkingObservation(
  'recognized',
  PlateOcrResult(
    frame: CameraFrame([1]),
    rawText: plate,
    provider: 'test',
    parkingPosition: position,
    noParkingViolation: position == 'inside',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inside buzzes once; uncertain and repeated LCD attempts stay silent',
    () async {
      var calls = 0;
      final buzzer = BayBuzzer(
        play: () async {
          calls++;
        },
      );
      await buzzer.observe(vehicle('outside'));
      await buzzer.observe(const ImageParkingObservation('uncertain', null));
      expect(calls, 0);
      await buzzer.observe(vehicle('inside'));
      await buzzer.observe(const ImageParkingObservation('uncertain', null));
      await buzzer.observe(vehicle('inside'));
      expect(calls, 1);
      await buzzer.observe(vehicle('inside', plate: 'MH12AB1234'));
      expect(calls, 2);
    },
  );

  test(
    'outside, empty scene and a new bay allow a fresh entry alert',
    () async {
      var calls = 0;
      final buzzer = BayBuzzer(
        play: () async {
          calls++;
        },
      );
      await buzzer.observe(vehicle('inside'));
      await buzzer.observe(vehicle('outside'));
      await buzzer.observe(vehicle('inside'));
      expect(calls, 2);
      await buzzer.observe(const ImageParkingObservation('empty', null));
      await buzzer.observe(vehicle('inside'));
      expect(calls, 3);
      buzzer.reset();
      await buzzer.observe(vehicle('inside'));
      expect(calls, 4);
    },
  );

  test(
    'failed audio can retry and concurrent observations do not double buzz',
    () async {
      var calls = 0;
      final pending = Completer<void>();
      final buzzer = BayBuzzer(
        play: () {
          calls++;
          return pending.future;
        },
      );
      final first = buzzer.observe(vehicle('inside'));
      await buzzer.observe(vehicle('inside'));
      expect(calls, 1);
      final failure = expectLater(first, throwsStateError);
      pending.completeError(StateError('Audio unavailable'));
      await failure;
      await expectLater(buzzer.observe(vehicle('inside')), throwsStateError);
      expect(calls, 2);
    },
  );

  test('Android confirmed entry calls the native buzzer channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('parkguard/bay_buzzer');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final buzzer = BayBuzzer();
    await buzzer.observe(vehicle('outside'));
    await buzzer.observe(vehicle('inside'));
    await buzzer.observe(vehicle('inside'));
    expect(calls.map((call) => call.method), ['buzz']);
  });
}
