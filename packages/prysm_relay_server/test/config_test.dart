/// `RelayConfig` is the operator's only knob set, so its validation is part of
/// the security surface: a bad value must fail at load, loudly.
library;

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

const _onion =
    'k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion';

Map<String, dynamic> _config({String bind = '127.0.0.1'}) => {
      'onion': _onion,
      'bind': bind,
      'port': 8443,
      'dataDir': '/var/lib/prysm-relay',
      'tenancy': 'private',
      'admission': 'invite',
    };

void main() {
  test('a loopback bind loads', () {
    for (final bind in ['127.0.0.1', '127.0.0.53', '::1', 'localhost']) {
      expect(
        RelayConfig.fromJson(_config(bind: bind)).bind,
        bind,
        reason: bind,
      );
    }
  });

  test('a routable bind is refused', () {
    for (final bind in ['0.0.0.0', '192.168.1.10', '::', 'relay.example']) {
      expect(
        () => RelayConfig.fromJson(_config(bind: bind)),
        throwsA(isA<FormatException>()),
        reason: bind,
      );
    }
  });

  test('requireLoopbackBind names the offending value', () {
    expect(
      () => RelayConfig.requireLoopbackBind('0.0.0.0'),
      throwsA(
        isA<RelayError>().having(
          (e) => e.message,
          'message',
          contains('0.0.0.0'),
        ),
      ),
    );
  });
}
