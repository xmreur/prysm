import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';

Future<({RatchetSession init, RatchetSession resp})> _pairedSessions() async {
  final shared = Uint8List.fromList(List.generate(32, (i) => i));
  final init = await RatchetSession.initializeAsInitiator(shared);
  final resp = await RatchetSession.initializeAsResponder(shared);
  return (init: init, resp: resp);
}

Future<String> _legacyRatchet1Wire(
  RatchetSession session,
  Uint8List plaintext,
) async {
  final counter = session.sendCounter;
  final role = session.isInitiator ? 'send' : 'recv';
  final salt = Uint8List.fromList(utf8.encode('prysm/ratchet/root-salt'));
  final messageKey = await CryptoKdf.hkdf(
    sharedSecret: session.sharedMaterial,
    info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/$role/msg/$counter'),
    salt: salt,
  );
  session.sendCounter++;
  final aeadKey = await CryptoAead.secretKeyFromBytes(
    Uint8List.fromList(await messageKey.extractBytes()),
  );
  final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
  return jsonEncode({
    'crypto': CryptoConstants.cryptoVersion,
    'scheme': CryptoConstants.schemeRatchet1,
    'nonce': base64Encode(enc.nonce),
    'ciphertext': base64Encode(enc.ciphertext),
    'counter': counter,
  });
}

void main() {
  group('Ratchet security', () {
    test('tampered counter does not advance recvCounter', () async {
      final pair = await _pairedSessions();
      final enc = await pair.init.encryptMessage(utf8.encode('hello'));
      final envelope = jsonDecode(enc.wire) as Map<String, dynamic>;
      envelope['counter'] = 999999;
      envelope['ciphertext'] = base64Encode(List.filled(32, 0));

      expect(
        () => pair.resp.decryptMessage(jsonEncode(envelope)),
        throwsA(isA<Exception>()),
      );
      expect(pair.resp.recvCounter, -1);

      final enc2 = await pair.init.encryptMessage(utf8.encode('next'));
      final plain = await pair.resp.decryptMessage(enc2.wire);
      expect(utf8.decode(plain), 'next');
    });

    test('large counter gap decrypts successfully', () async {
      final pair = await _pairedSessions();
      pair.init.sendCounter = 500;
      final enc = await pair.init.encryptMessage(utf8.encode('far ahead'));
      final plain = await pair.resp.decryptMessage(enc.wire);
      expect(utf8.decode(plain), 'far ahead');
      expect(pair.resp.recvCounter, 500);
    });

    test('scheme relabel fails decrypt on ratchet-2', () async {
      final pair = await _pairedSessions();
      final enc = await pair.init.encryptMessage(utf8.encode('bound'));
      final envelope = jsonDecode(enc.wire) as Map<String, dynamic>;
      envelope['scheme'] = CryptoConstants.schemeRatchet1;

      expect(
        () => pair.resp.decryptMessage(jsonEncode(envelope)),
        throwsA(isA<Exception>()),
      );
      expect(pair.resp.recvCounter, -1);
    });

    test('handshake rebind fails bootstrap decrypt', () async {
      final pair = await _pairedSessions();
      final handshake = {
        'ephemeralPub': base64Encode(List.filled(32, 1)),
        'oneTimePreKey': base64Encode(List.filled(32, 2)),
      };
      final enc = await pair.init.encryptMessage(
        utf8.encode('bootstrap'),
        handshake: handshake,
      );
      final envelope = jsonDecode(enc.wire) as Map<String, dynamic>;
      envelope['handshake'] = {
        ...handshake,
        'ephemeralPub': base64Encode(List.filled(32, 9)),
      };

      expect(
        () => pair.resp.decryptMessage(jsonEncode(envelope)),
        throwsA(isA<Exception>()),
      );
      expect(pair.resp.recvCounter, -1);

      final envelopeOk = jsonDecode(enc.wire) as Map<String, dynamic>;
      envelopeOk['handshake'] = handshake;
      final plain = await pair.resp.decryptMessage(jsonEncode(envelopeOk));
      expect(utf8.decode(plain), 'bootstrap');
    });

    test('ratchet-1 legacy wire still decrypts', () async {
      final pair = await _pairedSessions();
      final wire = await _legacyRatchet1Wire(pair.init, utf8.encode('legacy'));
      final plain = await pair.resp.decryptMessage(wire);
      expect(utf8.decode(plain), 'legacy');
    });
  });
}
