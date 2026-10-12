/// Motion speeds checks up; periodic full-image checks also catch a stationary
/// vehicle. There is no OCR prerequisite or lifetime two-attempt lockout.
class ImageScanPolicy {
  DateTime? _lastStart;
  DateTime? _nextAllowed;
  bool _motionPending = false;
  bool _empty = false;
  String? _acknowledged;
  int encounter = 0;

  void frame(DateTime now, {bool motion = false}) {
    if (motion) _motionPending = true;
  }

  bool canStart(DateTime now) =>
      (_lastStart == null ||
          now.difference(_lastStart!) >= const Duration(seconds: 8)) &&
      (_nextAllowed == null || !now.isBefore(_nextAllowed!));
  bool shouldScan(DateTime now) =>
      canStart(now) &&
      (_lastStart == null ||
          _motionPending ||
          now.difference(_lastStart!) >= const Duration(seconds: 30));
  bool start(DateTime now) {
    if (!canStart(now)) return false;
    _lastStart = now;
    _motionPending = false;
    return true;
  }

  void completed(DateTime now, {bool failed = false}) =>
      _nextAllowed = now.add(Duration(seconds: failed ? 30 : 2));
  void observeEmpty() {
    if (!_empty) {
      encounter++;
      _acknowledged = null;
    }
    _empty = true;
  }

  bool shouldRelay(String decision) => _acknowledged != decision;
  void acknowledge(String decision) {
    _acknowledged = decision;
    _empty = false;
  }

  void suspend() {
    _motionPending = false;
  }
}
