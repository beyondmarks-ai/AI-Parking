import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:parking_violation_app/motion_trigger.dart';

List<int> frame({required bool movingObject}) {
  final image = image_lib.Image(width: 64, height: 48);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final changed = movingObject && x >= 16 && x < 48;
      final value = changed ? 230 : 30;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image_lib.encodeJpg(image, quality: 100);
}

void main() {
  test('triggers immediately when a meaningful part of the scene moves', () {
    final trigger = MotionTrigger(sampleInterval: Duration.zero);
    final startedAt = DateTime(2026);

    expect(
      trigger.addFrame(frame(movingObject: false), capturedAt: startedAt),
      isFalse,
    );
    expect(
      trigger.addFrame(
        frame(movingObject: true),
        capturedAt: startedAt.add(const Duration(milliseconds: 100)),
      ),
      isTrue,
    );
  });

  test('ignores an unchanged scene and movement during cooldown', () {
    final trigger = MotionTrigger(sampleInterval: Duration.zero);
    final startedAt = DateTime(2026);
    final still = frame(movingObject: false);
    final moved = frame(movingObject: true);

    expect(trigger.addFrame(still, capturedAt: startedAt), isFalse);
    expect(
      trigger.addFrame(
        moved,
        capturedAt: startedAt.add(const Duration(milliseconds: 100)),
      ),
      isTrue,
    );
    expect(
      trigger.addFrame(
        still,
        capturedAt: startedAt.add(const Duration(milliseconds: 200)),
      ),
      isFalse,
    );
    expect(
      trigger.addFrame(
        moved,
        capturedAt: startedAt.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
  });
}
