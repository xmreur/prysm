import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/tor_bridge_config.dart';
import 'package:prysm/util/torrc_builder.dart';

void main() {
  const bridge =
      'obfs4 192.0.2.1:443 ABCDEF0123456789ABCDEF0123456789ABCDEF cert=abc iat-mode=0';

  test('desktop torrc omits bridges when disabled', () {
    final torrc = TorrcBuilder.desktopTorrc(
      controlPort: 9051,
      socksPort: 9050,
      dataDir: '/tmp/tor_data',
      hashedControlPassword: '16:deadbeef',
    );

    expect(torrc, contains('SocksPort 9050'));
    expect(torrc, isNot(contains('UseBridges')));
    expect(torrc, isNot(contains('ClientTransportPlugin')));
  });

  test('desktop torrc includes exec plugin and bridge lines', () {
    final torrc = TorrcBuilder.desktopTorrc(
      controlPort: 9051,
      socksPort: 9050,
      dataDir: '/tmp/tor_data',
      hashedControlPassword: '16:deadbeef',
      bridgeConfig: const TorBridgeConfig(useObfs4: true, bridges: [bridge]),
      lyrebirdExecPath: '/opt/lyrebird',
    );

    expect(torrc, contains('UseBridges 1'));
    expect(torrc, contains('ClientTransportPlugin obfs4 exec /opt/lyrebird'));
    expect(torrc, contains('Bridge $bridge'));
  });

  test('mobile torrc includes socks5 plugin when obfs4 active', () {
    final lines = TorrcBuilder.mobileTorrcLines(
      socksPort: 9050,
      controlPort: 9051,
      dataDirectory: '/data/tor',
      hiddenServiceDir: '/data/tor/hidden_service',
      logFile: '/data/tor/tor.log',
      bridgeConfig: const TorBridgeConfig(useObfs4: true, bridges: [bridge]),
      obfs4SocksPort: 34567,
    );

    expect(lines, contains('UseBridges 1'));
    expect(
      lines,
      contains('ClientTransportPlugin obfs4 socks5 127.0.0.1:34567'),
    );
    expect(lines, contains('Bridge $bridge'));
  });
}
