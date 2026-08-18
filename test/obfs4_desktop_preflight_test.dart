import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/tor_bridge_config.dart';
import 'package:prysm/util/lyrebird_locator.dart';
import 'package:prysm/util/obfs4_desktop_preflight.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('obfs4FailureMessage surfaces missing lyrebird text', () {
    final message = obfs4FailureMessage(
      StateError(LyrebirdLocator.bundledMissingMessage),
      useObfs4: true,
      l10n: l10n,
    );
    expect(message, l10n.obfs4LyrebirdMissingRebuild);
  });

  test('obfs4FailureMessage returns generic Tor failure when obfs4 is off', () {
    final message = obfs4FailureMessage(
      StateError('network down'),
      useObfs4: false,
      l10n: l10n,
    );
    expect(message, l10n.failedToConnectToTor);
  });

  test('obfs4FailureMessage returns no-bridge-lines copy', () {
    final message = obfs4FailureMessage(
      StateError('obfs4 is enabled but no valid bridge lines are configured'),
      useObfs4: true,
      l10n: l10n,
    );
    expect(message, l10n.obfs4NoBridgeLinesSaved);
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
