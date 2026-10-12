import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:visibility_detector/visibility_detector.dart';

class _CameraClient extends http.BaseClient {
  final frames = StreamController<List<int>>();
  int requests = 0;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(frames.stream, 200);
  }

  @override
  void close() => closes++;
}

void main() {
  testWidgets('scroll visibility keeps one stream; leaving closes it', (
    tester,
  ) async {
    final client = _CameraClient();
    final originalInterval =
        VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(() {
      VisibilityDetectorController.instance.updateInterval = originalInterval;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Mjpeg(
          stream: 'http://camera:81/stream',
          isLive: true,
          pauseWhenHidden: false,
          httpClient: client,
        ),
      ),
    );
    client.frames.add(img.encodeJpg(img.Image(width: 2, height: 2)));
    await tester.pump();
    final detector = tester.widget<VisibilityDetector>(
      find.byType(VisibilityDetector),
    );
    detector.onVisibilityChanged!(
      VisibilityInfo(
        key: detector.key!,
        size: const Size(100, 100),
        visibleBounds: Rect.zero,
      ),
    );
    await tester.pump();
    detector.onVisibilityChanged!(
      VisibilityInfo(
        key: detector.key!,
        size: const Size(100, 100),
        visibleBounds: const Rect.fromLTWH(0, 0, 100, 100),
      ),
    );
    await tester.pump();
    expect(client.requests, 1);
    expect(client.closes, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() async {
      await client.frames.close();
      await Future<void>.delayed(Duration.zero);
    });
    expect(client.closes, 1);
  });
}
