/// Scheduling and per-encounter limits, separate from OCR and widgets for tests.
class AutoPlateScanPolicy {
  DateTime? _motionWindowUntil;
  DateTime? _nextScanAt;
  DateTime? _emptySince;
  DateTime? _lastObservationAt;
  DateTime? _lastCloudAt;
  int _emptyScans = 0;
  int _cloudBursts = 0;
  String? acknowledgedPlate;
  int encounter = 0;
  bool _departureObserved = false;

  void frame(DateTime now, {bool motion = false}) {
    // Capture while something moves, not only after it has stopped. Keep a
    // short retry window so a car settling into position can still be read.
    if (motion) _motionWindowUntil = now.add(const Duration(seconds: 15));
  }

  bool shouldScan(DateTime now) {
    final until = _motionWindowUntil;
    if (until == null || now.isAfter(until)) {
      return false;
    }
    if (_nextScanAt != null && now.isBefore(_nextScanAt!)) return false;
    return true;
  }

  void completed(DateTime now) =>
      _nextScanAt = now.add(const Duration(seconds: 2));

  /// Absence must be observed repeatedly, not inferred from a timeout/error.
  void observe({required bool evidence, required DateTime now}) {
    if (_lastObservationAt != null &&
        now.difference(_lastObservationAt!).inSeconds > 10) {
      _emptySince = null;
      _emptyScans = 0;
    }
    _lastObservationAt = now;
    if (evidence) {
      _departureObserved = false;
      _emptySince = null;
      _emptyScans = 0;
      return;
    }
    _emptySince ??= now;
    _emptyScans++;
    if (!_departureObserved &&
        _emptyScans >= 3 &&
        now.difference(_emptySince!).inSeconds >= 8) {
      _departureObserved = true;
      encounter++;
      acknowledgedPlate = null;
      _cloudBursts = 0;
    }
  }

  bool reserveCloud(DateTime now, {required bool evidence}) {
    if (!evidence ||
        _cloudBursts >= 2 ||
        (_lastCloudAt != null &&
            now.difference(_lastCloudAt!).inSeconds < 30)) {
      return false;
    }
    _lastCloudAt = now;
    _cloudBursts++;
    return true;
  }

  bool shouldRelay(String plate) => acknowledgedPlate != plate;
  void acknowledge(String plate) {
    _departureObserved = false;
    acknowledgedPlate = plate;
    _emptySince = null;
    _emptyScans = 0;
  }

  /// Stream gaps, pause, and tab changes are not evidence that a car left.
  void suspend() {
    _motionWindowUntil = null;
    _nextScanAt = null;
    _emptySince = null;
    _emptyScans = 0;
    _lastObservationAt = null;
  }
}
