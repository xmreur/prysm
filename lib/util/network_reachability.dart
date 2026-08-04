import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:prysm/util/desktop_platform.dart';

/// OS-level link-up check: active WiFi/mobile/ethernet plus a non-loopback IPv4.
class NetworkReachability {
  NetworkReachability._();

  static const _linkUpTransports = {
    ConnectivityResult.wifi,
    ConnectivityResult.mobile,
    ConnectivityResult.ethernet,
  };

  static const _desktopLinkUpTransports = {
    ConnectivityResult.wifi,
    ConnectivityResult.mobile,
    ConnectivityResult.ethernet,
    ConnectivityResult.other,
  };

  /// Injectable probe for tests. Defaults to OS transport + local address checks.
  static Future<bool> Function({Duration timeout}) probe = _defaultProbe;

  /// Injectable connectivity check for tests.
  static Future<List<ConnectivityResult>> Function() checkConnectivity =
      () => Connectivity().checkConnectivity();

  /// Injectable network interface listing for tests.
  static Future<List<NetworkInterface>> Function() listNetworkInterfaces =
      () => NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: true,
      );

  /// Injectable desktop flag for tests. Defaults to [isDesktopPlatform].
  static bool isDesktop = isDesktopPlatform;

  static Future<bool> hasInternet({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      return await probe(timeout: timeout);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultProbe({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final results = await _safeCheckConnectivity();
    final linkUpTransports =
        isDesktop ? _desktopLinkUpTransports : _linkUpTransports;

    if (results.any(linkUpTransports.contains)) {
      return _hasNonLoopbackInterface();
    }

    // connectivity_plus on Linux requires NetworkManager; fall back to
    // interface checks on desktop when NM is absent (e.g. systemd-networkd).
    if (isDesktop) {
      return _hasNonLoopbackInterface();
    }

    return false;
  }

  static Future<List<ConnectivityResult>> _safeCheckConnectivity() async {
    try {
      return await checkConnectivity();
    } catch (_) {
      return [ConnectivityResult.none];
    }
  }

  static Future<bool> _hasNonLoopbackInterface() async {
    final interfaces = await listNetworkInterfaces();
    return interfaces.any(
      (iface) => iface.addresses.any((addr) => !addr.isLoopback),
    );
  }
}
