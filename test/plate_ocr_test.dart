import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_violation_app/plate_ocr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reads spaced and two-line plate formats without changing characters',
    () {
      expect(extractPlateCandidates('KA 01 AB 1234'), ['KA01AB1234']);
      expect(extractPlateCandidates('KA01\nAB1234'), ['KA01AB1234']);
      expect(extractPlateCandidates('22 BH 1234 AA'), ['22BH1234AA']);
      expect(extractPlateCandidates('KA O1 AB 1234'), isEmpty);
      expect(extractPlateCandidates('NO PARKING\n1234'), isEmpty);
      expect(extractPlateCandidates(''), isEmpty);
    },
  );

  test('keeps multiple possible numbers for review', () {
    expect(extractPlateCandidates('KA01AB1234\nKA01AB1234\nMH12CD5678'), [
      'KA01AB1234',
      'MH12CD5678',
    ]);
  });

  const channel = MethodChannel('parkguard/plate_ocr');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'returns actual native OCR text with the exact captured frame',
    () async {
      final frame = CameraFrame([255, 216, 255, 217]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'recognize');
            expect(call.arguments['jpeg'], frame.jpeg);
            return {'text': 'KA 01 AB 1234'};
          });
      final result = await PlateOcr().recognize(frame);
      expect(result.rawText, 'KA 01 AB 1234');
      expect(result.provider, 'on-device-ml-kit');
      expect(result.frame, same(frame));
      expect(result.candidates, ['KA01AB1234']);
    },
  );

  test('uses Azure OCR before the device recognizer', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/ocr/plate');
      expect(request.headers['content-type'], 'image/jpeg');
      expect(request.bodyBytes, [255, 216, 255, 217]);
      return http.Response(
        '{"provider":"azure-ai-vision","text":"KA 01 AB 1234","red_zone":{"left":0.2},"no_parking_violation":true,"fine_amount":500}',
        200,
      );
    });
    final result = await PlateOcr(
      apiBaseUrl: 'https://parkguard.example/',
      client: client,
    ).recognize(CameraFrame([255, 216, 255, 217]));
    expect(result.rawText, 'KA 01 AB 1234');
    expect(result.provider, 'azure-ai-vision');
    expect(result.redZoneDetected, isTrue);
    expect(result.noParkingViolation, isTrue);
    expect(result.fineAmount, 500);
    expect(result.candidates, ['KA01AB1234']);
  });

  test(
    'empty recognition stays empty instead of returning demo numbers',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => {'text': ''});
      final result = await PlateOcr().recognize(
        CameraFrame([255, 216, 255, 217]),
      );
      expect(result.rawText, isEmpty);
      expect(result.candidates, isEmpty);
    },
  );

  test(
    'native errors remain failures instead of becoming successful results',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'INVALID_IMAGE');
          });
      await expectLater(
        PlateOcr().recognize(CameraFrame([1])),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
