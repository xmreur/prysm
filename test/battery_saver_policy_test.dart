import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/battery_saver_policy.dart';

void main() {
  test('normal mode uses shorter polling intervals', () {
    expect(BatterySaverPolicy.chatPollActiveSeconds(false), 2);
    expect(BatterySaverPolicy.chatPollIdleSeconds(false), 5);
    expect(BatterySaverPolicy.homeRefreshInterval(false).inSeconds, 30);
    expect(BatterySaverPolicy.torHealthInterval(false).inSeconds, 15);
    expect(BatterySaverPolicy.peerStatusInterval(false).inSeconds, 90);
  });

  test('battery saving mode uses longer polling intervals', () {
    expect(BatterySaverPolicy.chatPollActiveSeconds(true), 8);
    expect(BatterySaverPolicy.chatPollIdleSeconds(true), 15);
    expect(BatterySaverPolicy.homeRefreshInterval(true).inSeconds, 120);
    expect(BatterySaverPolicy.torHealthInterval(true).inSeconds, 60);
    expect(BatterySaverPolicy.peerStatusInterval(true).inSeconds, 300);
    expect(BatterySaverPolicy.syncTickIdle(true).inSeconds, 120);
    expect(BatterySaverPolicy.syncTickBacklog(true).inSeconds, 30);
  });
}
