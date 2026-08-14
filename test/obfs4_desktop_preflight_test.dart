import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/tor_bridge_config.dart';
import 'package:prysm/util/lyrebird_locator.dart';
import 'package:prysm/util/obfs4_desktop_preflight.dart';

void main() {
  test('obfs4FailureMessage surfaces missing lyrebird text', () {
    final message = obfs4FailureMessage(
      StateError(LyrebirdLocator.bundledMissingMessage),
      useObfs4: true,
    );
    expect(message, contains(LyrebirdLocator.bundledMissingMessage));
    expect(message, contains('rebuild'));
  });

  test('preflight rejects useObfs4 without bridge lines', () async {
    await expectLater(
      preflightDesktopObfs4(
        const TorBridgeConfig(useObfs4: true, bridges: []),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
