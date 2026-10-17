import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'image_parking_analyzer.dart';

/// Audible alerts are independent of LCD delivery and its retry policy.
class BayBuzzer {
  BayBuzzer({Future<void> Function()? play}) : _play = play ?? _playPhoneBuzzer;

  static const _channel = MethodChannel('parkguard/bay_buzzer');
  final Future<void> Function() _play;
  final Set<String> _alertedPlates = {};
  int _generation = 0;

  static Future<void> _playPhoneBuzzer() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('buzz');
    } else {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  void reset() {
    _generation++;
    _alertedPlates.clear();
  }

  Future<void> observe(ImageParkingObservation observation) async {
    if (observation.status == 'empty') {
      reset();
      return;
    }
    final result = observation.result;
    if (observation.status != 'recognized' || result == null) return;
    final plates = result.candidates;
    if (plates.length != 1) return;
    final plate = plates.single;
    if (result.parkingPosition == 'outside') {
      _alertedPlates.remove(plate);
      return;
    }
    if (result.parkingPosition != 'inside' || !result.noParkingViolation) {
      return;
    }
    // Mark before awaiting so an overlapping observation cannot double-buzz.
    if (!_alertedPlates.add(plate)) return;
    final generation = _generation;
    try {
      await _play();
    } catch (_) {
      if (generation == _generation) _alertedPlates.remove(plate);
      rethrow;
    }
  }
}
