import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/models/tor_bridge_config.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/obfs4_bridge_parser.dart';
import 'package:prysm/util/obfs4_desktop_preflight.dart';

TorBridgeConfig torBridgeConfigFromSettings(Settings settings) {
  if (!settings.useObfs4) {
    return TorBridgeConfig.disabled;
  }
  final parsed = Obfs4BridgeParser.parse(settings.obfs4Bridges);
  return TorBridgeConfig(
    useObfs4: true,
    bridges: parsed.bridges,
  );
}

TorBridgeConfig torBridgeConfigFromSettingsService([SettingsService? service]) {
  final settings = (service ?? SettingsService()).settings;
  return torBridgeConfigFromSettings(settings);
}

String torConnectFailureMessage({
  required bool useObfs4,
  required AppLocalizations l10n,
}) {
  if (useObfs4) {
    return l10n.obfs4BridgesFailed;
  }
  return l10n.failedToConnectToTor;
}

/// Like [torConnectFailureMessage] but inspects the thrown error.
String torConnectFailureMessageFor(
  Object error, {
  required bool useObfs4,
  required AppLocalizations l10n,
}) =>
    obfs4FailureMessage(error, useObfs4: useObfs4, l10n: l10n);
