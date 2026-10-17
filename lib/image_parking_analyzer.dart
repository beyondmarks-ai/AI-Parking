import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'parking_zone.dart';
import 'account_session.dart';
import 'plate_burst.dart';
import 'plate_ocr.dart';

class ImageParkingObservation {
  const ImageParkingObservation(this.status, this.result);
  final String status;
  final PlateOcrResult? result;
}

/// Full-frame vision: no local OCR, text gate, crop or outside-bay mask.
class ImageParkingAnalyzer {
  ImageParkingAnalyzer({
    String apiBaseUrl = const String.fromEnvironment('API_BASE_URL'),
    http.Client? client,
  }) : _baseUrl = apiBaseUrl.trim().replaceFirst(RegExp(r'/$'), ''),
       _client = client ?? http.Client();
  final String _baseUrl;
  final http.Client _client;
  void close() => _client.close();

  Future<ImageParkingObservation> analyze(
    List<CameraFrame> frames, {
    required ParkingZone zone,
    required bool Function() isActive,
    String cameraSource = 'camera',
  }) async {
    if (_baseUrl.isEmpty) {
      throw StateError('Image analysis backend is not configured');
    }
    final eligible = frames.where((f) {
      final aspect = jpegAspectRatio(f.jpeg);
      return aspect != null && zone.matchesAspect(aspect);
    }).toList();
    final ranked = await compute(
      rankPlateFrames,
      eligible.map((f) => f.jpeg).toList(),
    );
    if (!isActive() || ranked.isEmpty) {
      return const ImageParkingObservation('uncertain', null);
    }
    final frame = eligible[ranked.first];
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/api/v1/parking/analyze'),
          headers: {
            ...AccountSession.headers,
            'Content-Type': 'image/jpeg',
            'X-Parking-Zone': zone.encode(),
            'X-Camera-Source': cameraSource,
            'X-Frame-Time': frame.capturedAt.toUtc().toIso8601String(),
          },
          body: frame.jpeg,
        )
        .timeout(const Duration(seconds: 25));
    if (!isActive()) return const ImageParkingObservation('uncertain', null);
    if (response.statusCode != 200) {
      throw StateError('Image analyzer unavailable (${response.statusCode})');
    }
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    if (value['status'] == 'empty' &&
        value['plate'] == null &&
        value['fine'] == null) {
      return const ImageParkingObservation('empty', null);
    }
    if (value['status'] != 'recognized') {
      return const ImageParkingObservation('uncertain', null);
    }
    final plate = value['plate'];
    final position = value['position'];
    final amount = value['fine_amount'];
    if (plate is! String ||
        extractPlateCandidates(plate).length != 1 ||
        extractPlateCandidates(plate).single != plate ||
        amount is! int ||
        !((position == 'inside' &&
                value['fine'] == true &&
                amount > 0 &&
                amount <= 99999) ||
            (position == 'outside' && value['fine'] == false && amount == 0))) {
      throw const FormatException('Invalid image-analysis decision');
    }
    return ImageParkingObservation(
      'recognized',
      PlateOcrResult(
        frame: frame,
        rawText: plate,
        provider: 'azure-foundry-image',
        parkingZone: zone,
        parkingPosition: position as String,
        noParkingViolation: value['fine'] == true,
        fineAmount: amount,
      ),
    );
  }
}
