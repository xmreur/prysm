import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:socks5_proxy/socks_client.dart';

void main() {
  test('assignTorSocksToHttpClient can be installed on HttpClient', () {
    final client = HttpClient();
    assignTorSocksToHttpClient(
      client,
      [ProxySettings(InternetAddress('127.0.0.1'), 9050)],
    );
    client.close(force: true);
  });

  test('TorHttpClient constructs with safe SOCKS binding', () {
    final client = TorHttpClient(proxyPort: 9050);
    expect(client, isNotNull);
  });
}
