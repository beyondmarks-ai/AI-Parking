import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Parses markers even when a camera splits them across TCP chunks.
class JpegFrameParser {
  JpegFrameParser({this.maxFrameBytes = 2 * 1024 * 1024});
  final int maxFrameBytes;
  final List<int> _frame = [];
  int _previous = -1;

  List<Uint8List> add(List<int> chunk) {
    final frames = <Uint8List>[];
    for (final byte in chunk) {
      if (_previous == 0xff && byte == 0xd8) {
        _frame
          ..clear()
          ..addAll([0xff, 0xd8]);
      } else if (_frame.isNotEmpty) {
        _frame.add(byte);
        if (_previous == 0xff && byte == 0xd9) {
          frames.add(Uint8List.fromList(_frame));
          _frame.clear();
        } else if (_frame.length > maxFrameBytes) {
          _frame.clear();
        }
      }
      _previous = byte;
    }
    return frames;
  }
}

/// One request at a time, with cancellation, frame watchdog and bounded retry.
class CameraStreamSession {
  CameraStreamSession({
    required this.url,
    required this.clientFactory,
    required this.onFrame,
    required this.onReconnecting,
    this.timeout = const Duration(seconds: 8),
    this.retryDelay = const Duration(seconds: 2),
  });

  final String url;
  final http.Client Function() clientFactory;
  final void Function(Uint8List) onFrame;
  final void Function() onReconnecting;
  final Duration timeout;
  final Duration retryDelay;
  http.Client? _client;
  Timer? _retryTimer;
  Completer<void>? _attempt;
  bool _disposed = false;
  bool _started = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final client = _client = clientFactory();
    final attempt = _attempt = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? watchdog;
    void endAttempt() {
      if (!attempt.isCompleted) attempt.complete();
    }

    void armWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(timeout, endAttempt);
    }

    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(timeout);
      if (_disposed) return;
      if (response.statusCode != 200) {
        throw StateError('Camera HTTP ${response.statusCode}');
      }
      final parser = JpegFrameParser();
      armWatchdog();
      subscription = response.stream.listen(
        (chunk) {
          if (_disposed || attempt.isCompleted) return;
          final frames = parser.add(chunk);
          if (frames.isNotEmpty) {
            armWatchdog();
            // If several frames arrive together, display the newest one.
            onFrame(frames.last);
          }
        },
        onError: (Object error) => endAttempt(),
        onDone: endAttempt,
        cancelOnError: true,
      );
      await attempt.future;
    } catch (_) {
      // The retry below also covers HTTP failures and header timeouts.
    } finally {
      watchdog?.cancel();
      client.close();
      await subscription?.cancel();
      _client = null;
      _attempt = null;
    }
    if (_disposed) return;
    onReconnecting();
    _retryTimer = Timer(retryDelay, () => unawaited(_connect()));
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _client?.close();
    final attempt = _attempt;
    if (attempt != null && !attempt.isCompleted) attempt.complete();
  }
}
