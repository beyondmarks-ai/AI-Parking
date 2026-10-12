import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'parking_zone.dart';

List<int> rankZonePlateFrames(
  ({List<Uint8List> frames, ParkingZone zone}) input,
) => rankPlateFrames(input.frames, zone: input.zone);

/// Runs in compute(), away from the live camera/UI isolate. Exact duplicate
/// frames cannot count as two independent observations.
List<int> rankPlateFrames(List<Uint8List> frames, {ParkingZone? zone}) {
  final scored = <({int index, double score})>[];
  final seen = <Uint8List>[];
  for (var i = 0; i < frames.length; i++) {
    if (seen.any((other) => _equal(other, frames[i]))) continue;
    seen.add(frames[i]);
    try {
      final decoded = img.decodeJpg(frames[i]);
      if (decoded == null) continue;
      if (zone != null && !zone.matchesAspect(decoded.width / decoded.height)) {
        continue;
      }
      final small = img.copyResize(decoded, width: 256);
      double sum = 0, squares = 0;
      var count = 0;
      double gray(int x, int y) => small.getPixel(x, y).luminance.toDouble();
      for (var y = 1; y < small.height - 1; y++) {
        for (var x = 1; x < small.width - 1; x++) {
          // Score only the bay interior. Excluding the neighbouring pixels
          // avoids letting a sharp background or artificial mask edge win.
          if (zone != null &&
              (!zone.contains((x - 1) / small.width, y / small.height) ||
                  !zone.contains((x + 1) / small.width, y / small.height) ||
                  !zone.contains(x / small.width, (y - 1) / small.height) ||
                  !zone.contains(x / small.width, (y + 1) / small.height))) {
            continue;
          }
          final lap =
              gray(x - 1, y) +
              gray(x + 1, y) +
              gray(x, y - 1) +
              gray(x, y + 1) -
              4 * gray(x, y);
          sum += lap;
          squares += lap * lap;
          count++;
        }
      }
      if (count > 0) {
        scored.add((
          index: i,
          score: squares / count - (sum / count) * (sum / count),
        ));
      }
    } catch (_) {
      /* Ignore malformed frames. */
    }
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored.take(3).map((entry) => entry.index).toList();
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Crop digit-bearing text using ML Kit bounds. If it cannot locate text,
/// preserve the whole frame so Foundry can locate the plate itself.
Uint8List cropPlateFrame(({Uint8List jpeg, List<double>? box}) input) {
  final source = img.decodeJpg(input.jpeg);
  if (source == null) return input.jpeg;
  var crop = source;
  final box = input.box;
  if (box != null && box.length == 4 && box.every((v) => v.isFinite)) {
    final left = (box[0] * source.width).floor().clamp(0, source.width - 1);
    final top = (box[1] * source.height).floor().clamp(0, source.height - 1);
    final right = (box[2] * source.width).ceil().clamp(left + 1, source.width);
    final bottom = (box[3] * source.height).ceil().clamp(
      top + 1,
      source.height,
    );
    crop = img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }
  final width = crop.width < 640 ? 640 : crop.width.clamp(1, 1280);
  return Uint8List.fromList(
    img.encodeJpg(
      img.copyResize(
        crop,
        width: width,
        interpolation: img.Interpolation.cubic,
      ),
      quality: 94,
    ),
  );
}
