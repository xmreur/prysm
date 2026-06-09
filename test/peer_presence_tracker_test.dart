import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/peer_presence_tracker.dart';
import 'package:prysm/util/battery_saver_policy.dart';

void main() {
  group('PeerPresenceTracker', () {
    late DateTime now;
    late PeerPresenceTracker tracker;

    setUp(() {
      now = DateTime(2026, 6, 9, 12, 0, 0);
      tracker = PeerPresenceTracker(now: () => now);
    });

    test('starts unknown', () {
      expect(tracker.isOnline, isNull);
    });

    test('activity within TTL is online', () {
      tracker.recordActivity();
      expect(tracker.isOnline, isTrue);

      now = now.add(const Duration(seconds: 30));
      expect(tracker.isOnline, isTrue);
    });

    test('TTL expired after activity is offline', () {
      tracker.recordActivity();
      now = now.add(BatterySaverPolicy.presenceActivityTtl());
      expect(tracker.isOnline, isFalse);
    });

    test('profile failure with recent activity stays online', () {
      tracker.recordActivity();
      tracker.considerProfileFailure(isHardFailure: true);
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isTrue);
    });

    test('two hard profile failures without activity is offline', () {
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isNull);
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isFalse);
    });

    test('three soft profile failures without activity is offline', () {
      tracker.considerProfileFailure(isHardFailure: false);
      tracker.considerProfileFailure(isHardFailure: false);
      expect(tracker.isOnline, isNull);
      tracker.considerProfileFailure(isHardFailure: false);
      expect(tracker.isOnline, isFalse);
    });

    test('recordActivity after offline probe returns online', () {
      tracker.considerProfileFailure(isHardFailure: true);
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isFalse);

      tracker.recordActivity();
      expect(tracker.isOnline, isTrue);
    });

    test('reset clears state', () {
      tracker.recordActivity();
      tracker.reset();
      expect(tracker.isOnline, isNull);
      expect(tracker.lastActivityAt, isNull);
    });

    test('suspended probe failures do not mark offline', () {
      tracker.suspendProbeFailuresFor(const Duration(minutes: 5));
      tracker.considerProfileFailure(isHardFailure: true);
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isNull);
    });

    test('probe failures resume after suspend expires', () {
      tracker.suspendProbeFailuresFor(const Duration(minutes: 1));
      now = now.add(const Duration(minutes: 2));
      tracker.considerProfileFailure(isHardFailure: true);
      tracker.considerProfileFailure(isHardFailure: true);
      expect(tracker.isOnline, isFalse);
    });
  });
}
