import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/call_foreground_session.dart';
import 'package:prysm/util/battery_saver_policy.dart';

void main() {
  tearDown(CallForegroundSession.resetForTest);

  test('ws heartbeat stays fast while call foreground session is active', () {
    CallForegroundSession.testOverride = _ActiveForegroundSession();

    expect(
      BatterySaverPolicy.wsHeartbeatInterval(true),
      const Duration(seconds: 30),
    );
  });
}

class _ActiveForegroundSession implements CallForegroundSessionPort {
  @override
  bool get inCall => true;

  @override
  Future<void> sync(snapshot, {previous}) async {}

  @override
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {}
}
