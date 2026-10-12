import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;

import 'parking_zone.dart';

/// Detects meaningful scene changes from a small luminance sample grid.
class MotionTrigger {
  MotionTrigger({
    this.sampleInterval = const Duration(milliseconds: 250),
    this.cooldown = const Duration(seconds: 2),
    this.pixelDifferenceThreshold = 30,
    this.changedPixelRatio = .10,
    this.sampleColumns = 24,
    this.sampleRows = 18,
  });

  final Duration sampleInterval;
  final Duration cooldown;
  final int pixelDifferenceThreshold;
  final double changedPixelRatio;
  final int sampleColumns;
  final int sampleRows;

  DateTime? _lastSampleAt;
  DateTime? _lastTriggeredAt;
  List<int>? _previousSample;

  bool addFrame(List<int> jpeg, {DateTime? capturedAt, ParkingZone? zone}) {
    final now = capturedAt ?? DateTime.now();
    final lastSampleAt = _lastSampleAt;
    if (lastSampleAt != null && now.difference(lastSampleAt) < sampleInterval) {
      return false;
    }
    _lastSampleAt = now;

    final decoded = image_lib.decodeImage(Uint8List.fromList(jpeg));
    if (decoded == null) return false;
    if (zone != null && !zone.matchesAspect(decoded.width / decoded.height)) {
      return false;
    }
    final sample = <int>[];
    for (var row = 0; row < sampleRows; row++) {
      final y = ((row + .5) * decoded.height / sampleRows).floor().clamp(
        0,
        decoded.height - 1,
      );
      for (var column = 0; column < sampleColumns; column++) {
        if (zone != null &&
            !zone.contains(
              (column + .5) / sampleColumns,
              (row + .5) / sampleRows,
            )) {
          continue;
        }
        final x = ((column + .5) * decoded.width / sampleColumns).floor().clamp(
          0,
          decoded.width - 1,
        );
        final pixel = decoded.getPixel(x, y);
        sample.add(
          (pixel.r.toInt() * 299 +
                  pixel.g.toInt() * 587 +
                  pixel.b.toInt() * 114) ~/
              1000,
        );
      }
    }

    final previous = _previousSample;
    _previousSample = sample;
    if (sample.isEmpty || previous == null || previous.length != sample.length) {
      return false;
    }

    var changed = 0;
    for (var index = 0; index < sample.length; index++) {
      if ((sample[index] - previous[index]).abs() >= pixelDifferenceThreshold) {
        changed++;
      }
    }
    if (changed / sample.length < changedPixelRatio) return false;

    final lastTriggeredAt = _lastTriggeredAt;
    if (lastTriggeredAt != null && now.difference(lastTriggeredAt) < cooldown) {
      return false;
    }
    _lastTriggeredAt = now;
    return true;
  }

  void reset() {
    _lastSampleAt = null;
    _lastTriggeredAt = null;
    _previousSample = null;
  }
}
