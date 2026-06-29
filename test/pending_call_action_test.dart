import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/pending_call_action.dart';

void main() {
  test('parses accept payload', () {
    final action = PendingCallAction.fromPayload(
      '{"type":"call","action":"accept","callId":"c1","peerOnion":"peer.onion"}',
    );
    expect(action?.action, CallNotificationAction.accept);
    expect(action?.callId, 'c1');
    expect(action?.peerOnion, 'peer.onion');
  });

  test('parses decline payload', () {
    final action = PendingCallAction.fromPayload(
      '{"type":"call","action":"decline","callId":"c2","peerOnion":"x.onion"}',
    );
    expect(action?.action, CallNotificationAction.decline);
  });

  test('active call body tap uses open action not hangup', () {
    final action = PendingCallAction.fromPayload(
      '{"type":"call","action":"open","callId":"c1","peerOnion":"peer.onion"}',
    );
    expect(action?.action, CallNotificationAction.open);
  });

  test('hangup action id overrides open payload', () {
    final action = PendingCallAction.fromResponse(
      NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        actionId: 'accept',
        payload:
            '{"type":"call","action":"open","callId":"c3","peerOnion":"p.onion"}',
      ),
    );
    expect(action?.action, CallNotificationAction.accept);
  });

  test('rejects non-call payloads', () {
    expect(
      PendingCallAction.fromPayload('{"senderId":"alice"}'),
      isNull,
    );
  });
}
