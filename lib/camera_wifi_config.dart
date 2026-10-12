import 'dart:async';

import 'camera_discovery.dart';

Future<void> updateCameraWifi({
  required String streamUrl,
  required String ssid,
  required String password,
}) async {
  final streamUri = Uri.parse(streamUrl);
  final controlPort = streamUri.hasPort && streamUri.port != 81
      ? streamUri.port
      : 80;
  final configUri = Uri(
    scheme: 'http',
    host: streamUri.host,
    port: controlPort,
    path: '/wifi-config',
  );
  final client = createCameraHttpClient();
  try {
    final response = await client
        .post(configUri, body: {'ssid': ssid, 'password': password})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      final detail = response.body.trim();
      throw CameraWifiConfigException(
        detail.isEmpty
            ? 'Camera rejected the Wi-Fi settings (${response.statusCode}).'
            : detail,
      );
    }
  } on TimeoutException {
    throw const CameraWifiConfigException(
      'The camera did not respond. Check that live video is connected.',
    );
  } finally {
    client.close();
  }
}

class CameraWifiConfigException implements Exception {
  const CameraWifiConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<void> sendParkingResultToCamera({
  required String streamUrl,
  required String plate,
  required int fineAmount,
}) async {
  final streamUri = Uri.parse(streamUrl);
  final controlPort = streamUri.hasPort && streamUri.port != 81
      ? streamUri.port
      : 80;
  final resultUri = Uri(
    scheme: 'http',
    host: streamUri.host,
    port: controlPort,
    path: '/lcd-result',
  );
  final client = createCameraHttpClient();
  try {
    final response = await client
        .post(resultUri, body: {'plate': plate, 'fine': fineAmount.toString()})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw CameraWifiConfigException(
        'ESP32 rejected the LCD result (${response.statusCode}).',
      );
    }
  } on TimeoutException {
    throw const CameraWifiConfigException(
      'ESP32 did not acknowledge the LCD result.',
    );
  } finally {
    client.close();
  }
}
