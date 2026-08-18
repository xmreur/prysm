import 'dart:io';

import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/tor_bridge_config.dart';
import 'package:prysm/util/lyrebird_locator.dart';

/// Validates desktop obfs4 prerequisites before Tor is restarted.
Future<void> preflightDesktopObfs4(TorBridgeConfig bridgeConfig) async {
  if (Platform.isAndroid || Platform.isIOS) return;
  if (!bridgeConfig.useObfs4) return;

  if (!bridgeConfig.isActive) {
    throw StateError(
      'obfs4 is enabled but no valid bridge lines are configured',
    );
  }

  final locator = LyrebirdLocator();
  await locator.resolveLyrebirdPath();
}

String obfs4FailureMessage(
  Object error, {
  required bool useObfs4,
  required AppLocalizations l10n,
}) {
  if (!useObfs4) {
    return l10n.failedToConnectToTor;
  }
  final text = error.toString();
  if (text.contains(LyrebirdLocator.bundledMissingMessage)) {
    return l10n.obfs4LyrebirdMissingRebuild;
  }
  if (text.contains('no valid bridge lines')) {
    return l10n.obfs4NoBridgeLinesSaved;
  }
  return l10n.obfs4BridgesFailed;
}
