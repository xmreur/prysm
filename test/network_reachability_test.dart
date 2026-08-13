import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/network_reachability.dart';

List<InternetAddress> _addrs(String host) => [InternetAddress(host)];

void main() {
  final originalProbe = NetworkReachability.probe;
  final originalCheckConnectivity = NetworkReachability.checkConnectivity;
  final originalListNetworkAddresses = NetworkReachability.listNetworkAddresses;
  final originalIsDesktop = NetworkReachability.isDesktop;

  tearDown(() {
    NetworkReachability.probe = originalProbe;
    NetworkReachability.checkConnectivity = originalCheckConnectivity;
    NetworkReachability.listNetworkAddresses = originalListNetworkAddresses;
    NetworkReachability.isDesktop = originalIsDesktop;
  });

  group('hasInternet probe override', () {
    test('returns true when probe succeeds', () async {
      NetworkReachability.probe =
          ({Duration timeout = const Duration(seconds: 3)}) async => true;

      expect(await NetworkReachability.hasInternet(), isTrue);
    });

    test('returns false when probe fails', () async {
      NetworkReachability.probe =
          ({Duration timeout = const Duration(seconds: 3)}) async => false;

      expect(await NetworkReachability.hasInternet(), isFalse);
    });

    test('returns false when probe throws', () async {
      NetworkReachability.probe =
          ({Duration timeout = const Duration(seconds: 3)}) async {
        throw Exception('network down');
      };

      expect(await NetworkReachability.hasInternet(), isFalse);
    });
  });

  group('default probe', () {
    setUp(() {
      NetworkReachability.probe = originalProbe;
    });

    Future<bool> runDefaultProbe({
      required List<ConnectivityResult> connectivity,
      required List<InternetAddress> addresses,
      bool isDesktop = true,
    }) async {
      NetworkReachability.isDesktop = isDesktop;
      NetworkReachability.checkConnectivity = () async => connectivity;
      NetworkReachability.listNetworkAddresses = () async => addresses;
      return NetworkReachability.hasInternet();
    }

    test('wifi with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.wifi],
          addresses: _addrs('192.168.1.5'),
        ),
        isTrue,
      );
    });

    test('mobile with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.mobile],
          addresses: _addrs('10.0.0.2'),
        ),
        isTrue,
      );
    });

    test('ethernet with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.ethernet],
          addresses: _addrs('192.168.0.10'),
        ),
        isTrue,
      );
    });

    test('no connectivity returns false on mobile', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.none],
          addresses: _addrs('192.168.1.5'),
          isDesktop: false,
        ),
        isFalse,
      );
    });

    test('desktop falls back to interfaces when connectivity is none', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.none],
          addresses: _addrs('192.168.1.71'),
          isDesktop: true,
        ),
        isTrue,
      );
    });

    test('desktop falls back to interfaces when connectivity throws', () async {
      NetworkReachability.isDesktop = true;
      NetworkReachability.checkConnectivity = () async {
        throw Exception('NetworkManager unavailable');
      };
      NetworkReachability.listNetworkAddresses =
          () async => _addrs('192.168.1.71');

      expect(await NetworkReachability.hasInternet(), isTrue);
    });

    test('wifi with only loopback returns false', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.wifi],
          addresses: _addrs('127.0.0.1'),
        ),
        isFalse,
      );
    });

    test('vpn only with local IPv4 returns false on mobile', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.vpn],
          addresses: _addrs('192.168.1.5'),
          isDesktop: false,
        ),
        isFalse,
      );
    });

    test('desktop other with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.other],
          addresses: _addrs('192.168.1.5'),
          isDesktop: true,
        ),
        isTrue,
      );
    });
  });
}
