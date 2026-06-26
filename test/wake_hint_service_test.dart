import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';

void main() {
  group('WakeHintService.validateSyncHintPayload', () {
    test('accepts valid payload', () {
      expect(
        WakeHintService.validateSyncHintPayload(
          {
            'senderId': 'peer.onion',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
          'me.onion',
        ),
        isNull,
      );
    });

    test('rejects self wake', () {
      expect(
        WakeHintService.validateSyncHintPayload(
          {
            'senderId': 'me.onion',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
          'me.onion',
        ),
        isNotNull,
      );
    });

    test('rejects stale timestamp', () {
      final stale = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      expect(
        WakeHintService.validateSyncHintPayload(
          {'senderId': 'peer.onion', 'timestamp': stale},
          'me.onion',
        ),
        isNotNull,
      );
    });
  });

  group('WakeHintService.handleIncomingHint', () {
    setUp(() {
      WakeHintService.instance.resetForTest();
    });

    test('skips flush when no pending outbound for sender', () async {
      var flushCount = 0;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async {
          flushCount++;
          return true;
        },
        hasOutboundPendingForSender: (_) async => false,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushCount, 0);
    });

    test('flushes when pending outbound exists for sender', () async {
      String? flushedPeer;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (peerId) async {
          flushedPeer = peerId;
          return true;
        },
        hasOutboundPendingForSender: (_) async => true,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushedPeer, 'peer.onion');
    });

    test('debounces repeated hints from same peer', () async {
      var flushCount = 0;
      WakeHintService.instance.configure(
        userId: 'me.onion',
        onFlushPeer: (_) async {
          flushCount++;
          return true;
        },
        hasOutboundPendingForSender: (_) async => true,
      );

      await WakeHintService.instance.handleIncomingHint('peer.onion');
      await WakeHintService.instance.handleIncomingHint('peer.onion');
      expect(flushCount, 1);
    });
  });

  test('wake hint policy constants are sensible', () {
    expect(BatterySaverPolicy.wakeHintMaxPeers, 20);
    expect(BatterySaverPolicy.wakeHintReceiveDebounce.inSeconds, 30);
    expect(BatterySaverPolicy.wakeHintSendCooldown.inMinutes, 5);
  });
}
