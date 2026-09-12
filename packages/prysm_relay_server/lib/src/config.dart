/// `RelayConfig`: the single JSON config from spec §5, with validation that
/// fails loudly on a bad config.
library;

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

/// Fixed-window quotas from spec §5. Keys are always application identities
/// (`deposit:<hex>`, `owner:<fpr>`), never an IP: every connection arrives
/// from the local Tor.
class RelayRateConfig {
  const RelayRateConfig({
    this.depositPerMinute = 60,
    this.pickupPerMinute = 30,
    this.pairPerHour = 10,
  });

  final int depositPerMinute;
  final int pickupPerMinute;
  final int pairPerHour;

  factory RelayRateConfig.fromJson(Object? json) {
    if (json == null) return const RelayRateConfig();
    if (json is! Map) {
      throw const FormatException('relay config: "rate" must be an object');
    }
    int pick(String key, int fallback) {
      final raw = json[key];
      if (raw == null) return fallback;
      if (raw is! int || raw <= 0) {
        throw FormatException(
          'relay config: "rate.$key" must be a positive int',
        );
      }
      return raw;
    }

    return RelayRateConfig(
      depositPerMinute: pick('depositPerMinute', 60),
      pickupPerMinute: pick('pickupPerMinute', 30),
      pairPerHour: pick('pairPerHour', 10),
    );
  }

  Map<String, dynamic> toJson() => {
        'depositPerMinute': depositPerMinute,
        'pickupPerMinute': pickupPerMinute,
        'pairPerHour': pairPerHour,
      };
}

class RelayConfig {
  const RelayConfig({
    required this.onion,
    required this.bind,
    required this.port,
    required this.dataDir,
    required this.tenancy,
    required this.admission,
    required this.allowedOwners,
    required this.limits,
    required this.rate,
    required this.logLevel,
    required this.terms,
  });

  final String onion;
  final String bind;
  final int port;
  final String dataDir;
  final RelayTenancy tenancy;
  final RelayAdmission admission;

  /// Fingerprints allowed to pair. Empty means no fingerprint restriction
  /// beyond [tenancy]/[admission].
  final List<String> allowedOwners;
  final RelayLimits limits;
  final RelayRateConfig rate;

  /// `counters` or `debug`.
  final String logLevel;

  /// Free text published in the manifest. Not in the spec §5 example, but the
  /// manifest (§3.1) carries `terms`, so the operator needs somewhere to set
  /// it; empty by default.
  final String terms;

  bool get isDebug => logLevel == 'debug';

  /// Defaults for `init`: ceilings from [RelayLimits.defaultsFor].
  factory RelayConfig.defaults({
    required String dataDir,
    RelayTenancy tenancy = RelayTenancy.private,
    String onion = '',
    String bind = '127.0.0.1',
    int port = 8443,
  }) =>
      RelayConfig(
        onion: onion,
        bind: bind,
        port: port,
        dataDir: dataDir,
        tenancy: tenancy,
        admission: RelayAdmission.invite,
        allowedOwners: const [],
        limits: RelayLimits.defaultsFor(tenancy),
        rate: const RelayRateConfig(),
        logLevel: 'counters',
        terms: '',
      );

  factory RelayConfig.fromJson(Map<String, dynamic> json) {
    try {
      return _parse(json);
    } on RelayError catch (e) {
      throw FormatException('relay config: ${e.message}');
    }
  }

  static RelayConfig _parse(Map<String, dynamic> json) {
    final tenancy = json.containsKey('tenancy')
        ? RelayTenancy.parse(json['tenancy'])
        : RelayTenancy.private;
    final admission = json.containsKey('admission')
        ? RelayAdmission.parse(json['admission'])
        : RelayAdmission.invite;

    final onion = json['onion'];
    if (onion is! String) {
      throw RelayError.badRequest('"onion" must be a string');
    }
    // Empty is allowed here so the operator can init before Tor exists; the
    // value is required to be a real onion by the time `serve` starts.
    if (onion.isNotEmpty) RelayFields.onion(onion, field: 'onion');

    final bind = json['bind'];
    if (bind is! String || bind.isEmpty) {
      throw RelayError.badRequest('"bind" must be a non-empty string');
    }
    final port = json['port'];
    if (port is! int || port <= 0 || port > 65535) {
      throw RelayError.badRequest('"port" must be 1..65535');
    }
    final dataDir = json['dataDir'];
    if (dataDir is! String || dataDir.isEmpty) {
      throw RelayError.badRequest('"dataDir" must be a non-empty string');
    }

    final rawOwners = json['allowedOwners'];
    var allowedOwners = const <String>[];
    if (rawOwners != null) {
      if (rawOwners is! List) {
        throw RelayError.badRequest('"allowedOwners" must be a list');
      }
      allowedOwners = [
        for (final e in rawOwners)
          RelayFields.fingerprint(e, field: 'allowedOwners[]'),
      ];
    }

    final rawLimits = json['limits'];
    final limits = rawLimits == null
        ? RelayLimits.defaultsFor(tenancy)
        : RelayLimits.fromJson(RelayFields.object(rawLimits, field: 'limits'));

    final logLevel = json['logLevel'];
    if (logLevel != null && logLevel != 'counters' && logLevel != 'debug') {
      throw RelayError.badRequest('"logLevel" must be "counters" or "debug"');
    }
    final terms = json['terms'];
    if (terms != null && terms is! String) {
      throw RelayError.badRequest('"terms" must be a string');
    }

    return RelayConfig(
      onion: onion,
      bind: bind,
      port: port,
      dataDir: dataDir,
      tenancy: tenancy,
      admission: admission,
      allowedOwners: allowedOwners,
      limits: limits,
      rate: RelayRateConfig.fromJson(json['rate']),
      logLevel: (logLevel as String?) ?? 'counters',
      terms: (terms as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'onion': onion,
        'bind': bind,
        'port': port,
        'dataDir': dataDir,
        'tenancy': tenancy.wire,
        'admission': admission.wire,
        'allowedOwners': allowedOwners,
        'limits': limits.toJson(),
        'rate': rate.toJson(),
        'logLevel': logLevel,
        'terms': terms,
      };
}
