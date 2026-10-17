import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'plate_ocr.dart';
import 'account_session.dart';

class PlateSnapshot {
  PlateSnapshot(this.result) : id = _newId() {
    if (result.candidates.length != 1) {
      throw ArgumentError('Exactly one confirmed plate is required');
    }
  }
  final String id;
  final PlateOcrResult result;
  String get plate => result.candidates.single;

  static String _newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Bounded in-memory upload queue. Never blocks the live preview/OCR loop.
class SnapshotArchive {
  SnapshotArchive({
    String apiBaseUrl = const String.fromEnvironment('API_BASE_URL'),
    http.Client? client,
    this.retryDelay = const Duration(seconds: 2),
  }) : _baseUrl = apiBaseUrl.replaceFirst(RegExp(r'/$'), ''),
       _client = client ?? http.Client();
  final String _baseUrl;
  final http.Client _client;
  final Duration retryDelay;
  final _queue = Queue<({PlateSnapshot snapshot, Completer<void> done})>();
  bool _closed = false;
  bool _running = false;
  int _outstanding = 0;

  Future<void> save(PlateSnapshot snapshot) {
    if (_closed || _baseUrl.isEmpty) {
      return Future.error(StateError('Snapshot storage is unavailable'));
    }
    if (_outstanding >= 3) {
      return Future.error(StateError('Snapshot upload queue is full'));
    }
    if (snapshot.result.frame.jpeg.length > 4 * 1024 * 1024) {
      return Future.error(StateError('Snapshot exceeds 4 MB'));
    }
    final done = Completer<void>();
    _queue.add((snapshot: snapshot, done: done));
    _outstanding++;
    if (!_running) unawaited(_drain());
    return done.future;
  }

  Future<void> _drain() async {
    _running = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      try {
        await _upload(job.snapshot);
        job.done.complete();
      } on Object catch (error, stack) {
        job.done.completeError(error, stack);
      } finally {
        _outstanding--;
      }
    }
    _running = false;
  }

  Future<void> _upload(PlateSnapshot snapshot) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_closed) throw StateError('Snapshot upload cancelled');
      var retryable = true;
      try {
        final response = await _client
            .put(
              Uri.parse('$_baseUrl/api/v1/captures/${snapshot.id}'),
              headers: {
                ...AccountSession.headers,
                'Content-Type': 'image/jpeg',
                'X-Plate-Number': snapshot.plate,
                'X-Captured-At': snapshot.result.frame.capturedAt
                    .toUtc()
                    .toIso8601String(),
                'X-Ocr-Provider': snapshot.result.provider,
                if (snapshot.result.parkingZone case final zone?)
                  'X-Parking-Zone': zone.encode(),
                if (snapshot.result.parkingPosition case final position?) ...{
                  'X-Parking-Decision': position,
                  'X-Fine-Amount': snapshot.result.fineAmount.toString(),
                },
              },
              body: snapshot.result.frame.jpeg,
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          retryable = response.statusCode == 429 || response.statusCode >= 500;
          throw StateError('Snapshot upload failed (${response.statusCode})');
        }
        retryable = false;
        final saved = jsonDecode(response.body) as Map<String, dynamic>;
        if (saved['saved'] != true ||
            saved['id'] != snapshot.id ||
            saved['plate'] != snapshot.plate) {
          throw const FormatException('Snapshot acknowledgment did not match');
        }
        return;
      } on Object {
        if (!retryable || attempt == 2 || _closed) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  void close() {
    _closed = true;
    _client.close();
    // Drain rejects queued work; callers receive errors, never a false success.
  }
}
