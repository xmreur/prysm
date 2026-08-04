import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// OS-level link-up check: active WiFi/mobile/ethernet plus a non-loopback IPv4.
class NetworkReachability {
  NetworkReachability._();

  static const _linkUpTransports = {
    ConnectivityResult.wifi,
    ConnectivityResult.mobile,
    ConnectivityResult.ethernet,
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
    final results = await checkConnectivity();
    if (!results.any(_linkUpTransports.contains)) {
      return false;
    }

    final interfaces = await listNetworkInterfaces();
    return interfaces.any(
      (iface) => iface.addresses.any((addr) => !addr.isLoopback),
    );
  }
}
