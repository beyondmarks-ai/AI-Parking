import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parking_violation_app/camera_discovery_io.dart';

Future<void> announceCamera(
  String url,
  String? gateway, {
  String? expectedUrl,
}) async {
  final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final packet = utf8.encode(
    'PARKGUARD_CAM $url${gateway == null ? '' : ' $gateway'}',
  );
  final discovery = discoverParkGuardCamera();
  final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
    sender.send(packet, InternetAddress.loopbackIPv4, 4211);
  });
  try {
    expect(
      await discovery.timeout(const Duration(seconds: 5)),
      expectedUrl ?? url,
    );
  } finally {
    timer.cancel();
    sender.close();
  }
}

void main() {
  test(
    'hotspot host uses its hotspot interface while upstream Wi-Fi is active',
    () {
      final source = selectCameraSourceAddress('10.111.71.18', [
        InternetAddress('192.168.1.4'),
        InternetAddress('10.111.71.15'),
      ]);
      expect(source?.address, '10.111.71.15');
    },
  );

  test(
    'guest phone uses its own address instead of the advertised gateway',
    () {
      final source = selectCameraSourceAddress('10.111.71.18', [
        InternetAddress('10.111.71.67'),
      ], advertisedSource: InternetAddress('10.111.71.15'));
      expect(source?.address, '10.111.71.67');
    },
  );

  test('network changes do not reuse an address the phone no longer owns', () {
    expect(
      selectCameraSourceAddress('10.111.71.18', [
        InternetAddress('192.168.1.4'),
      ], advertisedSource: InternetAddress('10.111.71.15')),
      isNull,
    );
  });

  late HttpServer camera;
  late String url;

  setUp(() async {
    camera = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${camera.port}/capture';
    camera.listen((request) async {
      request.response.persistentConnection = false;
      request.response.write('camera frame');
      await request.response.close();
    });
  });

  tearDown(() async {
    await camera.close(force: true);
  });

  test(
    'guest phone connects when advertised gateway is not a local address',
    () async {
      await announceCamera(url, '192.0.2.1');
      final client = createCameraHttpClient();
      addTearDown(client.close);
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      expect(response.body, 'camera frame');
    },
  );

  test(
    'hotspot owner can still bind an address belonging to this device',
    () async {
      await announceCamera(url, '127.0.0.1');
      final client = createCameraHttpClient();
      addTearDown(client.close);
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      expect(response.body, 'camera frame');
    },
  );

  test(
    'rediscovery recovers from a foreign gateway and announcements without one',
    () async {
      await announceCamera(url, '192.0.2.1');
      final client = createCameraHttpClient();
      addTearDown(client.close);
      await announceCamera(url, null);
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      expect(response.body, 'camera frame');
    },
  );

  test('adds the standard MJPEG port when an announcement omits it', () async {
    await announceCamera(
      'http://127.0.0.1/stream',
      null,
      expectedUrl: 'http://127.0.0.1:81/stream',
    );
  });
}
