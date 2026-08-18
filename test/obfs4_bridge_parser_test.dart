import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/util/obfs4_bridge_parser.dart';

void main() {
  const sampleBridge =
      'obfs4 192.0.2.1:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 cert=abc iat-mode=0';
  const sampleBridgeWithPrefix =
      'Bridge obfs4 192.0.2.3:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 cert=xyz iat-mode=0';

  group('Obfs4BridgeParser', () {
    test('parses a valid line', () {
      final result = Obfs4BridgeParser.parse(sampleBridge);
      expect(result.errors, isEmpty);
      expect(result.bridges, [sampleBridge]);
    });

    test('parses Bridge prefix', () {
      final result = Obfs4BridgeParser.parse(sampleBridgeWithPrefix);
      expect(result.errors, isEmpty);
      expect(
        result.bridges.first,
        startsWith('obfs4 192.0.2.3:443'),
      );
    });

    test('parses multiple lines and skips comments', () {
      final raw = '''
# provider bridge
$sampleBridge

$sampleBridgeWithPrefix
''';
      final result = Obfs4BridgeParser.parse(raw);
      expect(result.errors, isEmpty);
      expect(result.bridges, hasLength(2));
    });

    test('accepts IPv6 host', () {
      final line =
          'obfs4 [2001:db8::1]:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 cert=abc iat-mode=0';
      final result = Obfs4BridgeParser.parse(line);
      expect(result.errors, isEmpty);
      expect(result.bridges, [line]);
    });

    test('rejects missing cert=', () {
      final line =
          'obfs4 192.0.2.1:443 ABCDEF0123456789ABCDEF0123456789ABCDEF01 iat-mode=0';
      final result = Obfs4BridgeParser.parse(line);
      expect(result.bridges, isEmpty);
      expect(result.errors.single.kind, Obfs4ParseErrorKind.missingCert);
    });

    test('rejects snowflake transport', () {
      final line = 'snowflake 192.0.2.1:443 fingerprint';
      final result = Obfs4BridgeParser.parse(line);
      expect(result.bridges, isEmpty);
      expect(
        result.errors.single,
        const Obfs4ParseError(
          line: 1,
          kind: Obfs4ParseErrorKind.unsupportedTransport,
          transport: 'snowflake',
        ),
      );
    });

    test('empty input yields no bridges', () {
      final result = Obfs4BridgeParser.parse('\n  \n');
      expect(result.bridges, isEmpty);
      expect(result.errors, isEmpty);
    });
  });

  group('Settings obfs4 defaults', () {
    test('fromJson defaults missing keys', () {
      final settings = Settings.fromJson({});
      expect(settings.useObfs4, isFalse);
      expect(settings.obfs4Bridges, '');
    });

    test('round-trips obfs4 fields', () {
      final original = Settings(
        useObfs4: true,
        obfs4Bridges: sampleBridge,
      );
      final restored = Settings.fromJson(original.toJson());
      expect(restored.useObfs4, isTrue);
      expect(restored.obfs4Bridges, sampleBridge);
    });
  });
}
