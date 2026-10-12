import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'vehicle_detector.dart';

/// Owns the model and performs JPEG decoding, resizing and inference off the UI.
class VehicleDetectorWorker {
  final ReceivePort _responses = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  Isolate? _isolate;
  SendPort? _requests;
  Completer<VehicleDetectionResult>? _pending;
  bool _closed = false;

  static Future<VehicleDetectorWorker> load() async {
    final worker = VehicleDetectorWorker();
    worker._responses.listen((message) {
      if (message is SendPort) {
        worker._requests = message;
        worker._ready.complete();
      } else if (!worker._ready.isCompleted) {
        worker._ready.completeError(StateError('$message'));
      } else {
        final pending = worker._pending;
        worker._pending = null;
        if (message is VehicleDetectionResult) {
          pending?.complete(message);
        } else {
          pending?.completeError(StateError('$message'));
        }
      }
    });
    try {
      final asset = await rootBundle.load(
        'assets/models/vehicle_detector.tflite',
      );
      worker._isolate = await Isolate.spawn(_run, [
        worker._responses.sendPort,
        TransferableTypedData.fromList([asset.buffer.asUint8List()]),
      ]);
      await worker._ready.future.timeout(const Duration(seconds: 20));
      return worker;
    } catch (_) {
      worker._responses.close();
      worker._isolate?.kill();
      rethrow;
    }
  }

  Future<VehicleDetectionResult> detect(List<int> jpeg) {
    if (_closed) return Future.error(StateError('Detector closed'));
    if (_pending != null) return Future.error(StateError('Detector busy'));
    final pending = _pending = Completer<VehicleDetectionResult>();
    _requests!.send(Uint8List.fromList(jpeg));
    return pending.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _pending?.completeError(StateError('Detector closed'));
    _pending = null;
    _requests?.send(null);
    _responses.close();
  }

  static void _run(List<Object> arguments) {
    final responses = arguments[0] as SendPort;
    try {
      final model = (arguments[1] as TransferableTypedData).materialize();
      final detector = VehicleDetector.fromBytes(model.asUint8List());
      final requests = ReceivePort();
      responses.send(requests.sendPort);
      requests.listen((message) {
        if (message == null) {
          detector.close();
          requests.close();
          return;
        }
        try {
          responses.send(detector.detect(message as Uint8List));
        } catch (error) {
          responses.send(error.toString());
        }
      });
    } catch (error) {
      responses.send(error.toString());
    }
  }
}
