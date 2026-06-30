import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/network_reachability.dart';

void main() {
  final originalProbe = NetworkReachability.probe;

  tearDown(() {
    NetworkReachability.probe = originalProbe;
  });

  test('hasInternet returns true when probe succeeds', () async {
    NetworkReachability.probe =
        ({Duration timeout = const Duration(seconds: 3)}) async => true;

    expect(await NetworkReachability.hasInternet(), isTrue);
  });

  test('hasInternet returns false when probe fails', () async {
    NetworkReachability.probe =
        ({Duration timeout = const Duration(seconds: 3)}) async => false;

    expect(await NetworkReachability.hasInternet(), isFalse);
  });

  test('hasInternet returns false when probe throws', () async {
    NetworkReachability.probe =
        ({Duration timeout = const Duration(seconds: 3)}) async {
      throw Exception('network down');
    };

    expect(await NetworkReachability.hasInternet(), isFalse);
  });
}
