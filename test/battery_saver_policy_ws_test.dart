import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/util/battery_saver_policy.dart';

void main() {
  test('WakeHintService validates sync-hint payload', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
      WakeHintService.validateSyncHintPayload(
        {'senderId': 'peer.onion', 'timestamp': now},
        'local.onion',
      ),
      isNull,
    );
    expect(
      WakeHintService.validateSyncHintPayload(
        {'senderId': 'local.onion', 'timestamp': now},
        'local.onion',
      ),
      isNotNull,
    );
  });

  test('battery saver lengthens websocket heartbeat interval', () {
    expect(
      BatterySaverPolicy.wsHeartbeatInterval(false),
      const Duration(seconds: 30),
    );
    expect(
      BatterySaverPolicy.wsHeartbeatInterval(true),
      const Duration(seconds: 60),
    );
  });

  test('websocket safety poll interval is slower than active chat poll', () {
    expect(
      BatterySaverPolicy.wsSafetyPollSeconds,
      greaterThan(BatterySaverPolicy.chatPollActiveSeconds(false)),
    );
  });
}
