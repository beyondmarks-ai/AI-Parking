import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// Four ordered image-relative corners. This is an OCR region, not proof that
/// a vehicle is parked illegally. Camera movement requires recalibration.
class ParkingZone {
  ParkingZone(List<List<double>> corners, this.aspectRatio)
    : points = List.unmodifiable(
        corners.map((p) => List<double>.unmodifiable(p)),
      ) {
    if (!aspectRatio.isFinite ||
        aspectRatio < .2 ||
        aspectRatio > 5 ||
        points.length != 4 ||
        points.any(
          (p) => p.length != 2 || p.any((v) => !v.isFinite || v < 0 || v > 1),
        )) {
      throw const FormatException('Mark four corners inside the image');
    }
    double? direction;
    var area = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
      final cross =
          (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
      if (cross.abs() < .00001 ||
          (direction != null && cross * direction < 0)) {
        throw const FormatException('Tap corners in order around the bay');
      }
      direction = cross;
      area += a[0] * b[1] - b[0] * a[1];
    }
    if (area.abs() / 2 < .01) {
      throw const FormatException(
        'The bay must cover at least 1% of the image',
      );
    }
  }

  final List<List<double>> points;
  final double aspectRatio;
  bool matchesAspect(double aspect) => (aspect / aspectRatio - 1).abs() < .01;

  bool contains(double x, double y) {
    double? direction;
    for (var i = 0; i < 4; i++) {
      final a = points[i], b = points[(i + 1) % 4];
      final cross = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
      if (cross.abs() < 1e-9) continue;
      if (direction != null && direction * cross < 0) return false;
      direction = cross;
    }
    return true;
  }

  String encode() =>
      jsonEncode({'version': 1, 'aspect': aspectRatio, 'points': points});
  factory ParkingZone.decode(String source) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    if (map['version'] != 1) {
      throw const FormatException('Unknown zone version');
    }
    return ParkingZone(
      (map['points'] as List)
          .map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
          .toList(),
      (map['aspect'] as num).toDouble(),
    );
  }
}

double? jpegAspectRatio(Uint8List jpeg) {
  try {
    final info = img.JpegDecoder().startDecode(jpeg);
    return info == null ? null : info.width / info.height;
  } on Object {
    return null;
  }
}

/// Executed in a worker isolate. Original frames remain untouched for archive.
List<Uint8List> maskZoneFrames(
  ({List<Uint8List> frames, ParkingZone zone}) input,
) {
  return input.frames.map((jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null ||
        !input.zone.matchesAspect(decoded.width / decoded.height)) {
      throw const FormatException('Camera image changed; mark the bay again');
    }
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        if (!input.zone.contains(
          (x + .5) / decoded.width,
          (y + .5) / decoded.height,
        )) {
          decoded.setPixelRgb(x, y, 0, 0, 0);
        }
      }
    }
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 94));
  }).toList();
}

class ParkingZoneStore {
  static const channel = MethodChannel('parkguard/parking_zone');
  Future<ParkingZone?> load(String camera) async {
    try {
      final saved = await channel.invokeMethod<String>('load', {
        'camera': camera,
      });
      return saved == null ? null : ParkingZone.decode(saved);
    } on Object {
      // Missing/corrupt settings fail closed: live view only, no recognition.
      return null;
    }
  }

  Future<void> save(String camera, ParkingZone zone) => channel
      .invokeMethod<void>('save', {'camera': camera, 'zone': zone.encode()});
}
