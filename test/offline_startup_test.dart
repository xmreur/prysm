import 'package:flutter_test/flutter_test.dart';

/// Mirrors the post-unlock gate in [_MyAppState.build].
bool canEnterHome({required bool torReady, required bool offlineMode}) {
  return torReady || offlineMode;
}

void main() {
  test('home is blocked when Tor is not ready and not offline', () {
    expect(canEnterHome(torReady: false, offlineMode: false), isFalse);
  });

  test('home is reachable when Tor is ready', () {
    expect(canEnterHome(torReady: true, offlineMode: false), isTrue);
  });

  test('home is reachable in offline mode without Tor', () {
    expect(canEnterHome(torReady: false, offlineMode: true), isTrue);
  });

  test('home is reachable when both Tor is ready and offline flag is set', () {
    expect(canEnterHome(torReady: true, offlineMode: true), isTrue);
  });
}
