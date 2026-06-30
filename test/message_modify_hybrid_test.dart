import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/envelope.dart';

void main() {
  test('hybrid envelope detection', () {
    expect(
      CryptoEnvelope.isV2(
        '{"crypto":"v2","scheme":"dh-aead-1","ephemeralPub":"a","nonce":"b","ciphertext":"c"}',
      ),
      isTrue,
    );
    expect(CryptoEnvelope.isV2('not-json'), isFalse);
  });
}
