import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:parking_violation_app/plate_burst.dart';
import 'package:parking_violation_app/plate_ocr.dart';
import 'package:parking_violation_app/verified_plate_ocr.dart';
import 'package:parking_violation_app/parking_zone.dart';

Uint8List jpeg(int offset) {
  final image = img.Image(width: 80, height: 40);
  for (var y = 0; y < 40; y++) {
    for (var x = 0; x < 80; x++) {
      final v = (x + offset) % 10 < 5 ? 230 : 20;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plate = 'KA01AB1234';
  test('virtual bay masks local and cloud OCR; archives original; never calls red-strip assessment', () async {
    final zone = ParkingZone([
      [0, 0],
      [.5, 0],
      [.5, 1],
      [0, 1],
    ], 2);
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VerifiedPlateOcr.channel, (call) async {
          nativeCalls++;
          final image = img.decodeJpg(call.arguments['jpeg'] as Uint8List)!;
          expect(image.getPixel(70, 20).r, lessThan(5));
          return {'text': ''};
        });
    var cloudCalls = 0;
    final engine = VerifiedPlateOcr(
      apiBaseUrl: 'https://example.test',
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/ocr/foundry');
        cloudCalls++;
        final image = img.decodeJpg(request.bodyBytes)!;
        expect(
          image.getPixel(image.width * 7 ~/ 8, image.height ~/ 2).r,
          lessThan(5),
        );
        return http.Response('{"readable":true,"plate":"$plate"}', 200);
      }),
    );
    addTearDown(engine.close);
    final frames = [CameraFrame(jpeg(0)), CameraFrame(jpeg(2))];
    final result = await engine.recognize(frames, zone: zone);
    expect(nativeCalls, 2);
    expect(cloudCalls, 2);
    expect(result!.parkingZone, same(zone));
    expect(frames.contains(result.frame), isTrue);
    expect(
      img.decodeJpg(result.frame.jpeg)!.getPixel(70, 20).r,
      greaterThan(5),
    );
    expect(result.noParkingViolation, isFalse);
    expect(result.fineAmount, 0);
    await engine.assess(result);
    expect(cloudCalls, 2);
  });
  test('confirmation rejects conflicts, ambiguity, and lone guesses', () {
    expect(
      confirmedPlate([
        [plate],
        [plate],
      ], []),
      plate,
    );
    expect(
      confirmedPlate(
        [
          [plate],
          [],
        ],
        [
          [plate],
        ],
      ),
      plate,
    );
    expect(
      confirmedPlate(
        [[], []],
        [
          [plate],
          [plate],
        ],
      ),
      plate,
    );
    expect(
      confirmedPlate([
        [plate],
      ], []),
      isNull,
    );
    expect(
      confirmedPlate(
        [[]],
        [
          [plate],
        ],
      ),
      isNull,
    );
    expect(
      confirmedPlate(
        [
          [plate],
          ['KA01AB1235'],
        ],
        [
          [plate],
        ],
      ),
      isNull,
    );
    expect(
      confirmedPlate(
        [
          [plate, 'KA01AB1235'],
        ],
        [
          [plate],
          [plate],
        ],
      ),
      isNull,
    );
  });
  test(
    'sharp frames rank first; duplicates and invalid frames are removed',
    () {
      final sharp = jpeg(0);
      final blurred = Uint8List.fromList(
        img.encodeJpg(img.gaussianBlur(img.decodeJpg(sharp)!, radius: 8)),
      );
      expect(rankPlateFrames([blurred, sharp, sharp, Uint8List(0)]), [1, 0]);
    },
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VerifiedPlateOcr.channel, null),
  );
  test('two local readings avoid Foundry entirely', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          VerifiedPlateOcr.channel,
          (_) async => {'text': plate},
        );
    final calls = <String>[];
    final engine = VerifiedPlateOcr(
      apiBaseUrl: 'https://example.test',
      client: MockClient((req) async {
        calls.add(req.url.path);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(engine.close);
    final result = await engine.recognize([
      CameraFrame(jpeg(0)),
      CameraFrame(jpeg(2)),
    ]);
    expect(result?.candidates, [plate]);
    expect(calls, ['/api/v1/ocr/plate']); // Separate parking assessment only.
  });
  test(
    'cloud-only result requires two independently captured frames',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            VerifiedPlateOcr.channel,
            (_) async => {'text': ''},
          );
      var cloudCalls = 0;
      final engine = VerifiedPlateOcr(
        apiBaseUrl: 'https://example.test',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/foundry')) {
            cloudCalls++;
            expect(req.headers['content-type'], 'image/jpeg');
            return http.Response('{"readable":true,"plate":"$plate"}', 200);
          }
          return http.Response('{}', 200);
        }),
      );
      addTearDown(engine.close);
      final result = await engine.recognize([
        CameraFrame(jpeg(0)),
        CameraFrame(jpeg(3)),
      ]);
      expect(result?.candidates, [plate]);
      expect(cloudCalls, 2);
      final frozen = await engine.recognize([
        CameraFrame(jpeg(0)),
        CameraFrame(jpeg(0)),
      ]);
      expect(frozen, isNull);
      expect(cloudCalls, 2);
    },
  );
  test('local/cloud disagreement never becomes an LCD candidate', () async {
    var localCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          VerifiedPlateOcr.channel,
          (_) async => {'text': localCalls++ == 0 ? plate : ''},
        );
    final engine = VerifiedPlateOcr(
      apiBaseUrl: 'https://example.test',
      client: MockClient(
        (req) async =>
            http.Response('{"readable":true,"plate":"KA01AB1235"}', 200),
      ),
    );
    addTearDown(engine.close);
    expect(
      await engine.recognize([CameraFrame(jpeg(0)), CameraFrame(jpeg(3))]),
      isNull,
    );
  });

  test('local retries work with cloud disabled and parking deferred', () async {
    var localCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          VerifiedPlateOcr.channel,
          (_) async => {'text': localCalls++ < 2 ? '' : plate},
        );
    final engine = VerifiedPlateOcr(
      apiBaseUrl: 'https://example.test',
      client: MockClient(
        (req) async => throw StateError('Unexpected network call'),
      ),
    );
    addTearDown(engine.close);
    final frames = [CameraFrame(jpeg(0)), CameraFrame(jpeg(3))];
    bool? hasText;
    expect(
      await engine.recognize(
        frames,
        assessParking: false,
        allowCloud: (_) => false,
        onLocalObservation: (text, reliable) {
          hasText = text;
          expect(reliable, isTrue);
        },
      ),
      isNull,
    );
    expect(hasText, isFalse);
    expect(
      (await engine.recognize(
        frames,
        assessParking: false,
        allowCloud: (_) => false,
      ))?.candidates,
      [plate],
    );
  });

  test(
    'native failure is not an empty scene and cancelled work stops',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(VerifiedPlateOcr.channel, (_) async {
            calls++;
            throw PlatformException(code: 'OCR_FAILED');
          });
      final engine = VerifiedPlateOcr(apiBaseUrl: '');
      addTearDown(engine.close);
      bool? reliable;
      final frames = [CameraFrame(jpeg(0)), CameraFrame(jpeg(3))];
      await engine.recognize(
        frames,
        onLocalObservation: (_, value) => reliable = value,
      );
      expect(reliable, isFalse);
      expect(calls, 2);
      expect(await engine.recognize(frames, isActive: () => false), isNull);
      expect(calls, 2);
    },
  );

  test(
    'snapshot frame is one that actually supported the confirmed number',
    () async {
      final frames = [
        CameraFrame(jpeg(0)),
        CameraFrame(jpeg(2)),
        CameraFrame(jpeg(4)),
      ];
      final ranked = rankPlateFrames(frames.map((f) => f.jpeg).toList());
      var call = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            VerifiedPlateOcr.channel,
            (_) async => {'text': call++ == 0 ? '' : plate},
          );
      final engine = VerifiedPlateOcr(apiBaseUrl: '');
      addTearDown(engine.close);
      final result = await engine.recognize(frames, assessParking: false);
      expect(result?.frame, same(frames[ranked[1]]));
    },
  );
}
