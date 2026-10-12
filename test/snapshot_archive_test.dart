import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parking_violation_app/plate_ocr.dart';
import 'package:parking_violation_app/snapshot_archive.dart';
import 'package:parking_violation_app/parking_zone.dart';

PlateSnapshot snapshot() => PlateSnapshot(
  PlateOcrResult(
    frame: CameraFrame([255, 216, 255, 217]),
    rawText: 'KA01AB1234',
    provider: 'local OCR: multiple frames',
  ),
);

http.Response success(http.Request request) => http.Response(
  jsonEncode({
    'saved': true,
    'id': request.url.pathSegments.last,
    'plate':
        request.headers['X-Plate-Number'] ?? request.headers['x-plate-number'],
  }),
  200,
);

void main() {
  test('image decision and fine accompany the archived source frame', () async {
    final zone = ParkingZone([
      [0, 0],
      [1, 0],
      [1, 1],
      [0, 1],
    ], 2);
    final original = snapshot().result;
    final capture = PlateSnapshot(
      PlateOcrResult(
        frame: original.frame,
        rawText: original.rawText,
        provider: 'azure-foundry-image',
        parkingZone: zone,
        parkingPosition: 'outside',
        fineAmount: 0,
      ),
    );
    final archive = SnapshotArchive(
      apiBaseUrl: 'https://example.test',
      client: MockClient((request) async {
        expect(request.headers['x-parking-decision'], 'outside');
        expect(request.headers['x-fine-amount'], '0');
        expect(request.bodyBytes, original.frame.jpeg);
        return success(request);
      }),
    );
    addTearDown(archive.close);
    await archive.save(capture);
  });
  test('archives zone calibration with unmodified snapshot', () async {
    final zone = ParkingZone([
      [0, 0],
      [1, 0],
      [1, 1],
      [0, 1],
    ], 2);
    final original = snapshot().result;
    final capture = PlateSnapshot(
      PlateOcrResult(
        frame: original.frame,
        rawText: original.rawText,
        provider: original.provider,
        parkingZone: zone,
      ),
    );
    final archive = SnapshotArchive(
      apiBaseUrl: 'https://example.test',
      client: MockClient((request) async {
        expect(
          ParkingZone.decode(request.headers['x-parking-zone']!).points,
          zone.points,
        );
        expect(request.bodyBytes, original.frame.jpeg);
        return success(request);
      }),
    );
    addTearDown(archive.close);
    await archive.save(capture);
  });
  test(
    'uploads exact snapshot and metadata; retries reuse capture ID',
    () async {
      final capture = snapshot();
      final requests = <http.Request>[];
      final archive = SnapshotArchive(
        apiBaseUrl: 'https://example.test',
        retryDelay: Duration.zero,
        client: MockClient((request) async {
          requests.add(request);
          return requests.length == 1
              ? http.Response('', 502)
              : success(request);
        }),
      );
      addTearDown(archive.close);
      await archive.save(capture);
      expect(requests.length, 2);
      expect(requests.first.url, requests.last.url);
      expect(requests.last.method, 'PUT');
      expect(requests.last.bodyBytes, capture.result.frame.jpeg);
      expect(
        requests.last.headers['x-captured-at'],
        capture.result.frame.capturedAt.toUtc().toIso8601String(),
      );
      expect(
        capture.id,
        matches(
          RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ),
        ),
      );
    },
  );

  test(
    'does not report success for wrong acknowledgment or retry bad requests',
    () async {
      for (final response in [
        http.Response('{}', 200),
        http.Response('', 422),
      ]) {
        var calls = 0;
        final archive = SnapshotArchive(
          apiBaseUrl: 'https://example.test',
          retryDelay: Duration.zero,
          client: MockClient((_) async {
            calls++;
            return response;
          }),
        );
        await expectLater(archive.save(snapshot()), throwsA(isA<Object>()));
        expect(calls, 1);
        archive.close();
      }
    },
  );

  test(
    'queue is bounded to three snapshots and drains in the background',
    () async {
      final release = Completer<void>();
      var calls = 0;
      final archive = SnapshotArchive(
        apiBaseUrl: 'https://example.test',
        client: MockClient((request) async {
          calls++;
          if (calls == 1) await release.future;
          return success(request);
        }),
      );
      addTearDown(archive.close);
      final pending = [
        archive.save(snapshot()),
        archive.save(snapshot()),
        archive.save(snapshot()),
      ];
      await expectLater(archive.save(snapshot()), throwsStateError);
      release.complete();
      await Future.wait(pending);
      expect(calls, 3);
    },
  );

  test('closed archive rejects new uploads', () async {
    final archive = SnapshotArchive(apiBaseUrl: 'https://example.test')
      ..close();
    await expectLater(archive.save(snapshot()), throwsStateError);
  });
}
