/// Parses user-supplied obfs4 bridge lines for torrc `Bridge` directives.
class Obfs4BridgeParseResult {
  const Obfs4BridgeParseResult({
    required this.bridges,
    required this.errors,
  });

  final List<String> bridges;
  final List<String> errors;

  bool get hasValidBridges => bridges.isNotEmpty && errors.isEmpty;
}

class Obfs4BridgeParser {
  static final _fingerprintPattern = RegExp(r'^[0-9A-Fa-f]{40}$');
  static final _obfs4LinePattern = RegExp(
    r'^obfs4\s+(\S+)\s+([0-9A-Fa-f]{40})\s+(.+)$',
  );

  /// Returns normalized bridge lines without the `Bridge ` prefix.
  static Obfs4BridgeParseResult parse(String raw) {
    final bridges = <String>[];
    final errors = <String>[];

    for (final (index, line) in _iterLines(raw).indexed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      var body = trimmed;
      if (body.toLowerCase().startsWith('bridge ')) {
        body = body.substring('bridge '.length).trim();
      }

      if (!body.toLowerCase().startsWith('obfs4 ')) {
        final transport = body.split(RegExp(r'\s+')).firstOrNull ?? body;
        errors.add(
          'Line ${index + 1}: unsupported transport "$transport" (only obfs4 is supported)',
        );
        continue;
      }

      final match = _obfs4LinePattern.firstMatch(body);
      if (match == null) {
        errors.add(
          'Line ${index + 1}: invalid obfs4 line (expected obfs4 host:port fingerprint cert=…)',
        );
        continue;
      }

      final fingerprint = match.group(2)!;
      if (!_fingerprintPattern.hasMatch(fingerprint)) {
        errors.add('Line ${index + 1}: fingerprint must be 40 hex characters');
        continue;
      }

      final options = match.group(3)!;
      if (!options.contains('cert=')) {
        errors.add('Line ${index + 1}: missing cert= parameter');
        continue;
      }

      bridges.add(body);
    }

    return Obfs4BridgeParseResult(bridges: bridges, errors: errors);
  }

  static Iterable<String> _iterLines(String raw) sync* {
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      yield line;
    }
  }
}
