import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/network_reachability.dart';

class _FakeNetworkInterface implements NetworkInterface {
  _FakeNetworkInterface(this._addresses);

  final List<InternetAddress> _addresses;

  @override
  List<InternetAddress> get addresses => _addresses;

  @override
  int get index => 1;

  @override
  String get name => 'fake0';
}

List<NetworkInterface> _ifaces(String host) => [
  _FakeNetworkInterface([InternetAddress(host)]),
];

void main() {
  final originalProbe = NetworkReachability.probe;
  final originalCheckConnectivity = NetworkReachability.checkConnectivity;
  final originalListNetworkInterfaces = NetworkReachability.listNetworkInterfaces;
  final originalIsDesktop = NetworkReachability.isDesktop;

  tearDown(() {
    NetworkReachability.probe = originalProbe;
    NetworkReachability.checkConnectivity = originalCheckConnectivity;
    NetworkReachability.listNetworkInterfaces = originalListNetworkInterfaces;
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
      required List<NetworkInterface> interfaces,
      bool isDesktop = true,
    }) async {
      NetworkReachability.isDesktop = isDesktop;
      NetworkReachability.checkConnectivity = () async => connectivity;
      NetworkReachability.listNetworkInterfaces = () async => interfaces;
      return NetworkReachability.hasInternet();
    }

    test('wifi with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.wifi],
          interfaces: _ifaces('192.168.1.5'),
        ),
        isTrue,
      );
    });

    test('mobile with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.mobile],
          interfaces: _ifaces('10.0.0.2'),
        ),
        isTrue,
      );
    });

    test('ethernet with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.ethernet],
          interfaces: _ifaces('192.168.0.10'),
        ),
        isTrue,
      );
    });

    test('no connectivity returns false on mobile', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.none],
          interfaces: _ifaces('192.168.1.5'),
          isDesktop: false,
        ),
        isFalse,
      );
    });

    test('desktop falls back to interfaces when connectivity is none', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.none],
          interfaces: _ifaces('192.168.1.71'),
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
      NetworkReachability.listNetworkInterfaces =
          () async => _ifaces('192.168.1.71');

      expect(await NetworkReachability.hasInternet(), isTrue);
    });

    test('wifi with only loopback returns false', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.wifi],
          interfaces: _ifaces('127.0.0.1'),
        ),
        isFalse,
      );
    });

    test('vpn only with local IPv4 returns false on mobile', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.vpn],
          interfaces: _ifaces('192.168.1.5'),
          isDesktop: false,
        ),
        isFalse,
      );
    });

    test('desktop other with local IPv4 returns true', () async {
      expect(
        await runDefaultProbe(
          connectivity: [ConnectivityResult.other],
          interfaces: _ifaces('192.168.1.5'),
          isDesktop: true,
        ),
        isTrue,
      );
    });
  });
}
