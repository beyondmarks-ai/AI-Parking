import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:parking_violation_app/camera_stream_session.dart';

void main() {
  test('JPEG markers survive every single-byte TCP boundary', () {
    final parser = JpegFrameParser();
    final bytes = [0xff, 0xd8, 1, 2, 0xff, 0xd9];
    final frames = [
      for (final byte in [9, ...bytes, ...bytes]) ...parser.add([byte]),
    ];
    expect(frames, [bytes, bytes]);
  });

  test('oversized corrupt frames are discarded and parser recovers', () {
    final parser = JpegFrameParser(maxFrameBytes: 8);
    expect(parser.add([0xff, 0xd8, ...List.filled(20, 1)]), isEmpty);
    expect(parser.add([0xff, 0xd8, 2, 0xff, 0xd9]), [
      [0xff, 0xd8, 2, 0xff, 0xd9],
    ]);
  });

  for (final failure in ['disconnect', 'stall', 'http']) {
    test(
      'automatically recovers from $failure and stops retries on disposal',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final recovered = Completer<void>();
        final stalledResponses = <HttpResponse>[];
        var requests = 0;
        var reconnects = 0;
        server.listen((request) async {
          requests++;
          request.response.bufferOutput = false;
          request.response.headers.contentType = ContentType(
            'multipart',
            'x-mixed-replace',
          );
          if (requests == 1) {
            if (failure == 'http') {
              request.response.statusCode = 503;
              await request.response.close();
            } else if (failure == 'disconnect') {
              request.response.add([0xff, 0xd8, 1, 0xff, 0xd9]);
              await request.response.close();
            } else {
              // Bytes arrive but never form a frame: frame watchdog must fire.
              request.response.add([0xff, 0xd8, 1]);
              await request.response.flush();
              stalledResponses.add(request.response);
            }
          } else {
            request.response.add([0xff, 0xd8, 2, 0xff, 0xd9]);
            await request.response.flush();
            stalledResponses.add(request.response);
          }
        });
        final session = CameraStreamSession(
          url: 'http://127.0.0.1:${server.port}/stream',
          clientFactory: IOClient.new,
          timeout: const Duration(milliseconds: 600),
          retryDelay: const Duration(milliseconds: 30),
          onFrame: (frame) {
            if (frame[2] == 2 && !recovered.isCompleted) recovered.complete();
          },
          onReconnecting: () => reconnects++,
        );
        try {
          session.start();
          await recovered.future.timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              throw StateError(
                'Recovery timed out: requests=$requests reconnects=$reconnects',
              );
            },
          );
          expect(reconnects, greaterThanOrEqualTo(1));
          session.dispose();
          final stoppedAt = requests;
          await Future<void>.delayed(const Duration(milliseconds: 800));
          expect(requests, stoppedAt);
        } finally {
          session.dispose();
          for (final response in stalledResponses) {
            try {
              await response.close();
            } catch (_) {}
          }
          await server.close(force: true);
        }
      },
    );
  }
}
