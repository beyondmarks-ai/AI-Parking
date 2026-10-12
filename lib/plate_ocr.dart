import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'parking_zone.dart';

class CameraFrame {
  CameraFrame(List<int> bytes, {DateTime? capturedAt})
    : jpeg = Uint8List.fromList(bytes),
      capturedAt = capturedAt ?? DateTime.now();

  final Uint8List jpeg;
  final DateTime capturedAt;

  bool get isFresh =>
      DateTime.now().difference(capturedAt) < const Duration(seconds: 5);
}

class PlateOcrResult {
  const PlateOcrResult({
    required this.frame,
    required this.rawText,
    required this.provider,
    this.noParkingViolation = false,
    this.fineAmount = 0,
    this.redZoneDetected = false,
    this.parkingZone,
    this.parkingPosition,
  });

  final CameraFrame frame;
  final String rawText;
  final String provider;
  final bool noParkingViolation;
  final int fineAmount;
  final bool redZoneDetected;
  final ParkingZone? parkingZone;
  final String? parkingPosition;

  List<String> get candidates => extractPlateCandidates(rawText);
}

/// Format matching is a review aid, not registration validation. Do not replace
/// ambiguous OCR characters (O/0, I/1, etc.) or invent a number on failure.
List<String> extractPlateCandidates(String text) {
  final matches = <String>{};
  final pattern = RegExp(
    r'^(?:[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}|[0-9]{2}BH[0-9]{4}[A-Z]{1,2})$',
  );
  final lines = text.toUpperCase().split(RegExp(r'[\r\n]+'));
  for (var index = 0; index < lines.length; index++) {
    for (var count = 1; count <= 2 && index + count <= lines.length; count++) {
      final value = lines
          .sublist(index, index + count)
          .join()
          .replaceAll(RegExp(r'[\s-]'), '');
      if (pattern.hasMatch(value)) matches.add(value);
    }
  }
  return matches.toList();
}

class PlateOcr {
  static const _channel = MethodChannel('parkguard/plate_ocr');
  static const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');

  PlateOcr({String apiBaseUrl = _configuredApiBaseUrl, http.Client? client})
    : _apiBaseUrl = apiBaseUrl.trim().replaceFirst(RegExp(r'/$'), ''),
      _client = client ?? http.Client();

  final String _apiBaseUrl;
  final http.Client _client;

  Future<PlateOcrResult> recognize(CameraFrame frame) async {
    Object? azureError;
    if (_apiBaseUrl.isNotEmpty) {
      try {
        return await _recognizeWithAzure(frame);
      } on Object catch (error) {
        azureError = error;
      }
    }

    try {
      return await _recognizeOnDevice(frame);
    } on Object catch (deviceError) {
      if (azureError != null) {
        throw StateError(
          'Azure OCR failed ($azureError); device OCR also failed ($deviceError).',
        );
      }
      rethrow;
    }
  }

  Future<PlateOcrResult> _recognizeWithAzure(CameraFrame frame) async {
    final response = await _client
        .post(
          Uri.parse('$_apiBaseUrl/api/v1/ocr/plate'),
          headers: const {'Content-Type': 'image/jpeg'},
          body: frame.jpeg,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Invalid OCR response');
    }
    return PlateOcrResult(
      frame: frame,
      rawText: (payload['text'] as String? ?? '').trim(),
      provider: payload['provider'] as String? ?? 'azure-ai-vision',
      noParkingViolation: payload['no_parking_violation'] == true,
      fineAmount: (payload['fine_amount'] as num?)?.toInt() ?? 0,
      redZoneDetected: payload['red_zone'] != null,
    );
  }

  Future<PlateOcrResult> _recognizeOnDevice(CameraFrame frame) async {
    final result = await _channel
        .invokeMapMethod<String, dynamic>('recognize', {'jpeg': frame.jpeg})
        .timeout(const Duration(seconds: 20));
    return PlateOcrResult(
      frame: frame,
      rawText: (result?['text'] as String? ?? '').trim(),
      provider: 'on-device-ml-kit',
    );
  }
}
