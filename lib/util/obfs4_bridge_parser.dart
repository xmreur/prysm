/// Parses user-supplied obfs4 bridge lines for torrc `Bridge` directives.
class Obfs4BridgeParseResult {
  const Obfs4BridgeParseResult({
    required this.bridges,
    required this.errors,
  });

  final List<String> bridges;
  final List<Obfs4ParseError> errors;

  bool get hasValidBridges => bridges.isNotEmpty && errors.isEmpty;
}

enum Obfs4ParseErrorKind {
  unsupportedTransport,
  invalidLine,
  fingerprintInvalid,
  missingCert,
}

class Obfs4ParseError {
  const Obfs4ParseError({
    required this.line,
    required this.kind,
    this.transport,
  });

  final int line;
  final Obfs4ParseErrorKind kind;
  final String? transport;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Obfs4ParseError &&
          line == other.line &&
          kind == other.kind &&
          transport == other.transport;

  @override
  int get hashCode => Object.hash(line, kind, transport);
}

class Obfs4BridgeParser {
  static final _fingerprintPattern = RegExp(r'^[0-9A-Fa-f]{40}$');
  static final _obfs4LinePattern = RegExp(
    r'^obfs4\s+(\S+)\s+([0-9A-Fa-f]{40})\s+(.+)$',
  );

  /// Returns normalized bridge lines without the `Bridge ` prefix.
  static Obfs4BridgeParseResult parse(String raw) {
    final bridges = <String>[];
    final errors = <Obfs4ParseError>[];

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
          Obfs4ParseError(
            line: index + 1,
            kind: Obfs4ParseErrorKind.unsupportedTransport,
            transport: transport,
          ),
        );
        continue;
      }

      final match = _obfs4LinePattern.firstMatch(body);
      if (match == null) {
        errors.add(
          Obfs4ParseError(
            line: index + 1,
            kind: Obfs4ParseErrorKind.invalidLine,
          ),
        );
        continue;
      }

      final fingerprint = match.group(2)!;
      if (!_fingerprintPattern.hasMatch(fingerprint)) {
        errors.add(
          Obfs4ParseError(
            line: index + 1,
            kind: Obfs4ParseErrorKind.fingerprintInvalid,
          ),
        );
        continue;
      }

      final options = match.group(3)!;
      if (!options.contains('cert=')) {
        errors.add(
          Obfs4ParseError(
            line: index + 1,
            kind: Obfs4ParseErrorKind.missingCert,
          ),
        );
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
