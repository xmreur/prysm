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

    test('WS connected is online', () {
      tracker.recordWsConnected();
      expect(tracker.isOnline, isTrue);
    });

    test('WS disconnected is offline', () {
      tracker.recordWsDisconnected();
      expect(tracker.isOnline, isFalse);
    });

    test('WS connected takes priority over expired activity', () {
      tracker.recordActivity();
      now = now.add(BatterySaverPolicy.presenceActivityTtl());
      tracker.recordWsConnected();
      expect(tracker.isOnline, isTrue);
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

    test('activity with WS disconnected stays online via TTL', () {
      tracker.recordWsDisconnected();
      tracker.recordActivity();
      expect(tracker.isOnline, isTrue);
    });

    test('recordActivity after WS offline returns online', () {
      tracker.recordWsDisconnected();
      expect(tracker.isOnline, isFalse);

      tracker.recordActivity();
      expect(tracker.isOnline, isTrue);
    });

    test('clearWsState returns unknown when no activity', () {
      tracker.recordWsDisconnected();
      tracker.clearWsState();
      expect(tracker.isOnline, isNull);
    });

    test('reset clears state', () {
      tracker.recordWsConnected();
      tracker.reset();
      expect(tracker.isOnline, isNull);
      expect(tracker.lastActivityAt, isNull);
    });
  });
}
