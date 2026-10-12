import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'plate_burst.dart';
import 'plate_ocr.dart';
import 'parking_zone.dart';

/// Reject conflicts/multiple plates. Two local frames suffice. One local
/// reading plus the independent cloud reading can agree; cloud-only readings
/// require two distinct frames. Model-reported confidence is never a vote.
String? confirmedPlate(List<List<String>> local, List<List<String>> cloud) {
  final all = [...local, ...cloud];
  if (all.any((r) => r.length > 1)) return null;
  final values = all.expand((r) => r).toSet();
  if (values.length != 1) return null;
  final localVotes = local.where((r) => r.length == 1).length;
  final cloudVotes = cloud.where((r) => r.length == 1).length;
  return localVotes >= 2 ||
          (localVotes >= 1 && cloudVotes >= 1) ||
          cloudVotes >= 2
      ? values.single
      : null;
}

class VerifiedPlateOcr {
  VerifiedPlateOcr({
    String apiBaseUrl = const String.fromEnvironment('API_BASE_URL'),
    http.Client? client,
  }) : baseUrl = apiBaseUrl.trim().replaceFirst(RegExp(r'/$'), ''),
       _client = client ?? http.Client();
  static const channel = MethodChannel('parkguard/plate_ocr');
  final String baseUrl;
  final http.Client _client;
  void close() => _client.close();

  Future<PlateOcrResult?> recognize(
    List<CameraFrame> frames, {
    bool Function(bool hasText)? allowCloud,
    void Function(bool hasText, bool reliable)? onLocalObservation,
    bool assessParking = true,
    bool Function()? isActive,
    ParkingZone? zone,
  }) async {
    final images = frames.map((f) => f.jpeg).toList();
    final ranked = zone == null
        ? await compute(rankPlateFrames, images)
        : await compute(rankZonePlateFrames, (frames: images, zone: zone));
    if (isActive != null && !isActive()) return null;
    if (ranked.length < 2) return null;
    final selected = ranked.map((i) => frames[i]).toList();
    // Full-resolution masking is needed only for the best three frames.
    final originals = ranked.map((i) => images[i]).toList();
    final selectedImages = zone == null
        ? originals
        : await compute(maskZoneFrames, (frames: originals, zone: zone));
    final local = <List<String>>[];
    final boxes = <List<double>?>[];
    var hasText = false;
    var successfulReadings = 0;
    for (final jpeg in selectedImages) {
      if (isActive != null && !isActive()) return null;
      Map<String, dynamic>? reading;
      try {
        reading = await channel
            .invokeMapMethod<String, dynamic>('recognize', {'jpeg': jpeg})
            .timeout(const Duration(seconds: 3));
        if (reading != null) successfulReadings++;
      } on Object {
        /* Two cloud frames can still confirm if native OCR fails. */
      }
      final box = (reading?['plateBox'] as List?)
          ?.map((v) => (v as num).toDouble())
          .toList();
      boxes.add(box);
      final text = (reading?['text'] as String? ?? '').trim();
      hasText = hasText || RegExp(r'\d').hasMatch(text);
      local.add(extractPlateCandidates(text));
    }
    if (isActive != null && !isActive()) return null;
    onLocalObservation?.call(hasText, successfulReadings == selected.length);
    final fastPlate = confirmedPlate(local, const []);
    if (fastPlate != null) {
      return _result(
        selected[local.indexWhere((votes) => votes.contains(fastPlate))],
        fastPlate,
        'local OCR: multiple frames',
        assessParking: assessParking,
        zone: zone,
      );
    }
    if (baseUrl.isEmpty || (allowCloud != null && !allowCloud(hasText))) {
      return null;
    }
    final cloud = <List<String>>[];
    // The model receives no local guesses, avoiding anchored transcription.
    for (var i = 0; i < selected.length && i < 2; i++) {
      if (isActive != null && !isActive()) return null;
      final jpeg = await compute(cropPlateFrame, (
        jpeg: selectedImages[i],
        box: boxes[i],
      ));
      if (isActive != null && !isActive()) return null;
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/v1/ocr/foundry'),
            headers: {'Content-Type': 'image/jpeg'},
            body: jpeg,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError(
          'Cloud verification unavailable (${response.statusCode})',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final text = payload['readable'] == true
          ? payload['plate'] as String? ?? ''
          : '';
      cloud.add(extractPlateCandidates(text));
      final plate = confirmedPlate(local, cloud);
      if (plate != null) {
        return _result(
          selected[cloud.indexWhere((votes) => votes.contains(plate))],
          plate,
          'local / Foundry verification',
          assessParking: assessParking,
          zone: zone,
        );
      }
    }
    return null;
  }

  Future<PlateOcrResult> _result(
    CameraFrame frame,
    String plate,
    String provider, {
    bool assessParking = true,
    ParkingZone? zone,
  }) async {
    // Keep parking assessment separate; a number alone is not a violation.
    var violation = false;
    var redZone = false;
    var fine = 0;
    if (zone == null && assessParking && baseUrl.isNotEmpty) {
      try {
        final response = await _client
            .post(
              Uri.parse('$baseUrl/api/v1/ocr/plate'),
              headers: {'Content-Type': 'image/jpeg'},
              body: frame.jpeg,
            )
            .timeout(const Duration(seconds: 6));
        if (response.statusCode == 200) {
          final payload = jsonDecode(response.body) as Map<String, dynamic>;
          redZone = payload['red_zone'] != null;
          final details = payload['candidate_details'] as List? ?? [];
          violation = details.any(
            (d) => d is Map && d['plate'] == plate && d['restricted'] == true,
          );
          fine = violation ? (payload['fine_amount'] as num? ?? 0).toInt() : 0;
        }
      } on Object {
        /* A confirmed plate is usable without zone assessment. */
      }
    }
    return PlateOcrResult(
      frame: frame,
      rawText: plate,
      provider: provider,
      noParkingViolation: violation,
      fineAmount: fine,
      redZoneDetected: redZone,
      parkingZone: zone,
    );
  }

  Future<PlateOcrResult> assess(PlateOcrResult result) => _result(
    result.frame,
    result.candidates.single,
    result.provider,
    zone: result.parkingZone,
  );
}
