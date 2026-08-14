import 'dart:io';

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

String obfs4FailureMessage(Object error, {required bool useObfs4}) {
  if (!useObfs4) {
    return 'Failed to connect to Tor. Check your network and try again.';
  }
  final text = error.toString();
  if (text.contains(LyrebirdLocator.bundledMissingMessage)) {
    return '${LyrebirdLocator.bundledMissingMessage} Then rebuild the app.';
  }
  if (text.contains('no valid bridge lines')) {
    return 'obfs4 is on but no valid bridge lines are saved — paste a bridge line or turn obfs4 off.';
  }
  return 'obfs4 bridges failed — check your bridge lines or turn obfs4 off.';
}
