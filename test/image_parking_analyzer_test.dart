import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:parking_violation_app/image_parking_analyzer.dart';
import 'package:parking_violation_app/image_scan_policy.dart';
import 'package:parking_violation_app/parking_zone.dart';
import 'package:parking_violation_app/plate_ocr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final zone = ParkingZone([
    [0, 0],
    [.5, 0],
    [.5, 1],
    [0, 1],
  ], 2);
  final frame = CameraFrame(img.encodeJpg(img.Image(width: 160, height: 80)));
  Map<String, Object?> decision(bool fine) => {
    'status': 'recognized',
    'plate': 'KA58W0344',
    'position': fine ? 'inside' : 'outside',
    'fine': fine,
    'fine_amount': fine ? 500 : 0,
  };

  test(
    'one original full frame goes directly to image analyzer, never native OCR',
    () async {
      var nativeCalls = 0;
      const ocr = MethodChannel('parkguard/plate_ocr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ocr, (_) async {
            nativeCalls++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ocr, null),
      );
      for (final fine in [true, false]) {
        final engine = ImageParkingAnalyzer(
          apiBaseUrl: 'https://test',
          client: MockClient((request) async {
            expect(request.url.path, '/api/v1/parking/analyze');
            expect(request.bodyBytes, frame.jpeg);
            expect(request.headers['x-parking-zone'], zone.encode());
            return http.Response(jsonEncode(decision(fine)), 200);
          }),
        );
        final result = (await engine.analyze(
          [frame],
          zone: zone,
          isActive: () => true,
        )).result!;
        expect(result.frame, same(frame));
        expect(result.fineAmount, fine ? 500 : 0);
        expect(result.parkingPosition, fine ? 'inside' : 'outside');
        engine.close();
      }
      expect(nativeCalls, 0);
    },
  );
  test('inconsistent or malformed fine decisions are rejected', () async {
    for (final invalid in [
      {...decision(true), 'fine_amount': 0},
      {...decision(false), 'fine_amount': 500},
      {...decision(true), 'plate': 'UNKNOWN'},
      {...decision(true), 'fine': null},
    ]) {
      final engine = ImageParkingAnalyzer(
        apiBaseUrl: 'https://test',
        client: MockClient(
          (_) async => http.Response(jsonEncode(invalid), 200),
        ),
      );
      await expectLater(
        engine.analyze([frame], zone: zone, isActive: () => true),
        throwsFormatException,
      );
      engine.close();
    }
  });
  test('cancelled analysis cannot produce a relay result', () async {
    var active = true;
    final engine = ImageParkingAnalyzer(
      apiBaseUrl: 'https://test',
      client: MockClient((_) async {
        active = false;
        return http.Response(jsonEncode(decision(true)), 200);
      }),
    );
    final result = await engine.analyze(
      [frame],
      zone: zone,
      isActive: () => active,
    );
    expect(result.result, isNull);
    engine.close();
  });
  test('empty and uncertain scenes never produce a no-fine plate', () async {
    for (final status in ['empty', 'uncertain']) {
      final engine = ImageParkingAnalyzer(
        apiBaseUrl: 'https://test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'status': status, 'plate': null, 'fine': null}),
            200,
          ),
        ),
      );
      expect(
        (await engine.analyze(
          [frame],
          zone: zone,
          isActive: () => true,
        )).result,
        isNull,
      );
      engine.close();
    }
  });
  test(
    'stationary images retry periodically without the old two-attempt lockout',
    () {
      final policy = ImageScanPolicy();
      final start = DateTime(2026);
      for (var i = 0; i < 6; i++) {
        final now = start.add(Duration(seconds: 30 * i));
        expect(policy.shouldScan(now), isTrue);
        expect(policy.start(now), isTrue);
        policy.completed(now.add(const Duration(seconds: 4)));
        expect(policy.shouldScan(now.add(const Duration(seconds: 7))), isFalse);
      }
    },
  );
  test('motion accelerates checks, errors back off, and pause preserves rate limit', () {
    final policy = ImageScanPolicy();
    final now = DateTime(2026);
    policy.start(now);
    policy.frame(now, motion: true);
    policy.completed(now.add(const Duration(seconds: 2)));
    expect(policy.shouldScan(now.add(const Duration(seconds: 7))), isFalse);
    expect(policy.shouldScan(now.add(const Duration(seconds: 8))), isTrue);
    policy.start(now.add(const Duration(seconds: 8)));
    policy.completed(now.add(const Duration(seconds: 9)), failed: true);
    policy.suspend();
    expect(policy.start(now.add(const Duration(seconds: 20))), isFalse);
    expect(policy.shouldScan(now.add(const Duration(seconds: 39))), isTrue);
  });
  test('same plate moving inside to outside updates LCD, same decision is suppressed', () {
    final policy = ImageScanPolicy();
    policy.acknowledge('KA58W0344:inside:500');
    expect(policy.shouldRelay('KA58W0344:inside:500'), isFalse);
    expect(policy.shouldRelay('KA58W0344:outside:0'), isTrue);
    policy.acknowledge('KA58W0344:outside:0');
    policy.observeEmpty();
    expect(policy.shouldRelay('KA58W0344:outside:0'), isTrue);
  });
}
