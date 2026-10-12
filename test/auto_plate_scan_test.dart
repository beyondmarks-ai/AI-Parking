import 'package:flutter_test/flutter_test.dart';
import 'package:parking_violation_app/auto_plate_scan.dart';

void main() {
  final start = DateTime(2026, 10, 12);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  test('idle scene waits for motion, then retries within a bounded window', () {
    final policy = AutoPlateScanPolicy()..frame(start);
    expect(policy.shouldScan(start), isFalse);
    expect(policy.shouldScan(at(1)), isFalse);
    policy.frame(at(1), motion: true);
    for (var seconds = 1; seconds < 16; seconds += 3) {
      expect(policy.shouldScan(at(seconds)), isTrue);
      policy.completed(at(seconds));
      expect(policy.shouldScan(at(seconds + 1)), isFalse);
    }
    expect(policy.shouldScan(at(17)), isFalse);
    policy.frame(at(20), motion: true);
    expect(policy.shouldScan(at(20)), isTrue);
  });

  test(
    'captures during movement and continuing movement extends the window',
    () {
      final policy = AutoPlateScanPolicy()..frame(start, motion: true);
      expect(policy.shouldScan(start), isTrue);
      policy.completed(start);
      expect(policy.shouldScan(at(1)), isFalse);
      policy.frame(at(14), motion: true);
      expect(policy.shouldScan(at(20)), isTrue);
      policy.suspend();
      expect(policy.shouldScan(at(21)), isFalse);
    },
  );

  test('same plate is suppressed until repeated empty-scene observations', () {
    final policy = AutoPlateScanPolicy()..acknowledge('KA01AB1234');
    expect(policy.shouldRelay('KA01AB1234'), isFalse);
    expect(policy.shouldRelay('KA01AB1235'), isTrue);
    policy.observe(evidence: false, now: at(0));
    policy.observe(evidence: false, now: at(4));
    expect(policy.shouldRelay('KA01AB1234'), isFalse);
    policy.observe(
      evidence: true,
      now: at(7),
    ); // Blur/partial text: still here.
    policy.observe(evidence: false, now: at(8));
    policy.observe(evidence: false, now: at(12));
    expect(policy.shouldRelay('KA01AB1234'), isFalse);
    policy.observe(evidence: false, now: at(16));
    expect(policy.shouldRelay('KA01AB1234'), isTrue);
  });

  test('disconnect, pause, or observation gaps never imply departure', () {
    final policy = AutoPlateScanPolicy()..acknowledge('KA01AB1234');
    policy.observe(evidence: false, now: at(0));
    policy.observe(evidence: false, now: at(4));
    policy.suspend();
    expect(policy.shouldScan(at(20)), isFalse);
    policy.observe(evidence: false, now: at(20));
    expect(policy.shouldRelay('KA01AB1234'), isFalse);
    policy.observe(evidence: false, now: at(200));
    expect(policy.shouldRelay('KA01AB1234'), isFalse);
  });

  test('cloud needs evidence, has cooldown, and stops after two bursts', () {
    final policy = AutoPlateScanPolicy();
    expect(policy.reserveCloud(at(0), evidence: false), isFalse);
    expect(policy.reserveCloud(at(0), evidence: true), isTrue);
    expect(policy.reserveCloud(at(29), evidence: true), isFalse);
    expect(policy.reserveCloud(at(30), evidence: true), isTrue);
    policy.suspend();
    expect(policy.reserveCloud(at(90), evidence: true), isFalse);
    policy.observe(evidence: false, now: at(91));
    policy.observe(evidence: false, now: at(95));
    policy.observe(evidence: false, now: at(99));
    expect(policy.reserveCloud(at(100), evidence: true), isTrue);
  });
}
