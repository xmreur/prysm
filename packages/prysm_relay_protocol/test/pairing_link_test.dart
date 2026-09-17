import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:test/test.dart';

void main() {
  const onion = 'jzckm6hv2ujfba2ju5td6bzx66fe36bmweug2vjlnoykeqeng6f27wad.onion';
  final fpr = 'a' * 64;
  final token = '0123456789abcdef' * 4;
  final link = 'prysm-relay://pair?onion=$onion&fpr=$fpr&token=$token';

  test('round-trips the three values in canonical order', () {
    final parsed = RelayPairingLink.parse(link);
    expect(parsed.onion, onion);
    expect(parsed.fingerprint, fpr);
    expect(parsed.token, token);
    expect(parsed.encode(), link);
  });

  test('tolerates surrounding whitespace and a slash before the query', () {
    expect(RelayPairingLink.parse('  $link\n').onion, onion);
    final slashed = link.replaceFirst('pair?', 'pair/?');
    expect(RelayPairingLink.parse(slashed).token, token);
    expect(RelayPairingLink.looksLike(slashed), isTrue);
  });

  test('rejects a missing or malformed field with bad_request', () {
    for (final bad in [
      'prysm-relay://pair?onion=$onion&fpr=$fpr',
      'prysm-relay://pair?onion=not-an-onion&fpr=$fpr&token=$token',
      'prysm-relay://pair?onion=$onion&fpr=${'A' * 64}&token=$token',
      'prysm-relay://pair?onion=$onion&fpr=$fpr&token=short',
      'https://pair?onion=$onion&fpr=$fpr&token=$token',
      'prysm-relay://other?onion=$onion&fpr=$fpr&token=$token',
    ]) {
      expect(
        () => RelayPairingLink.parse(bad),
        throwsA(isA<RelayError>()
            .having((e) => e.code, 'code', RelayErrorCode.badRequest)),
        reason: bad,
      );
    }
  });

  test('looksLike is a cheap prefix check, not validation', () {
    expect(RelayPairingLink.looksLike('prysm-relay://pair?garbage'), isTrue);
    expect(RelayPairingLink.looksLike(onion), isFalse);
    expect(RelayPairingLink.looksLike(''), isFalse);
  });
}
