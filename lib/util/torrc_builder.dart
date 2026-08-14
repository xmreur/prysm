import 'dart:io';

import 'package:prysm/models/tor_bridge_config.dart';

/// Builds torrc fragments shared by desktop and tests.
class TorrcBuilder {
  static String desktopTorrc({
    required int controlPort,
    required int socksPort,
    required String dataDir,
    required String hashedControlPassword,
    TorBridgeConfig bridgeConfig = TorBridgeConfig.disabled,
    String? lyrebirdExecPath,
  }) {
    final buffer = StringBuffer()
      ..writeln('ControlPort $controlPort')
      ..writeln('SocksPort $socksPort')
      ..writeln('DataDirectory $dataDir')
      ..writeln('HashedControlPassword $hashedControlPassword')
      ..writeln('CookieAuthentication 1')
      ..writeln('HiddenServiceDir $dataDir/hidden_service/')
      ..writeln('HiddenServicePort 80 127.0.0.1:12345');

    appendObfs4Desktop(
      buffer: buffer,
      bridgeConfig: bridgeConfig,
      lyrebirdExecPath: lyrebirdExecPath,
    );

    return buffer.toString();
  }

  static void appendObfs4Desktop({
    required StringBuffer buffer,
    required TorBridgeConfig bridgeConfig,
    String? lyrebirdExecPath,
  }) {
    if (!bridgeConfig.isActive) return;
    if (lyrebirdExecPath == null || lyrebirdExecPath.isEmpty) {
      throw StateError('lyrebird path required when obfs4 bridges are enabled');
    }

    final execPath = Platform.isWindows ? '"$lyrebirdExecPath"' : lyrebirdExecPath;
    buffer
      ..writeln('UseBridges 1')
      ..writeln('ClientTransportPlugin obfs4 exec $execPath');
    for (final bridge in bridgeConfig.bridges) {
      buffer.writeln('Bridge $bridge');
    }
  }

  static List<String> mobileTorrcLines({
    required int socksPort,
    required int controlPort,
    required String dataDirectory,
    required String hiddenServiceDir,
    required String logFile,
    String? cacheDirectory,
    String? geoIpFile,
    String? geoIpv6File,
    TorBridgeConfig bridgeConfig = TorBridgeConfig.disabled,
    int obfs4SocksPort = 0,
  }) {
    final lines = <String>[
      'SocksPort $socksPort',
      'ControlPort $controlPort',
      'DataDirectory $dataDirectory',
      if (cacheDirectory != null) 'CacheDirectory $cacheDirectory',
      'CookieAuthentication 1',
      'HiddenServiceDir $hiddenServiceDir',
      'HiddenServicePort 80 127.0.0.1:12345',
      'Log notice file $logFile',
      'SafeLogging 1',
      if (geoIpFile != null) 'GeoIPFile $geoIpFile',
      if (geoIpv6File != null) 'GeoIPv6File $geoIpv6File',
    ];

    if (bridgeConfig.isActive && obfs4SocksPort > 0) {
      lines.add('UseBridges 1');
      lines.add('ClientTransportPlugin obfs4 socks5 127.0.0.1:$obfs4SocksPort');
      for (final bridge in bridgeConfig.bridges) {
        lines.add('Bridge $bridge');
      }
    }

    return lines;
  }
}
