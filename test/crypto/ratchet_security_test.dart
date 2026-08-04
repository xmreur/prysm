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
    sharedSecret: session.sharedMaterial!,
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
      envelope['counter'] = 10;
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
      pair.init.sendCounter = 200;
      final enc = await pair.init.encryptMessage(utf8.encode('far ahead'));
      final plain = await pair.resp.decryptMessage(enc.wire);
      expect(utf8.decode(plain), 'far ahead');
      expect(pair.resp.recvCounter, 200);
      expect(pair.resp.skippedCounters.length, 200);
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

    test('out-of-order 1 then 0 decrypts both', () async {
      final pair = await _pairedSessions();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      final enc1 = await pair.init.encryptMessage(utf8.encode('one'));

      final plain1 = await pair.resp.decryptMessage(enc1.wire);
      expect(utf8.decode(plain1), 'one');
      expect(pair.resp.recvCounter, 1);
      expect(pair.resp.skippedCounters, {0});

      final plain0 = await pair.resp.decryptMessage(enc0.wire);
      expect(utf8.decode(plain0), 'zero');
      expect(pair.resp.recvCounter, 1);
      expect(pair.resp.skippedCounters, isEmpty);
    });

    test('out-of-order 2 then 0 then 1 decrypts all', () async {
      final pair = await _pairedSessions();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      final enc1 = await pair.init.encryptMessage(utf8.encode('one'));
      final enc2 = await pair.init.encryptMessage(utf8.encode('two'));

      expect(utf8.decode(await pair.resp.decryptMessage(enc2.wire)), 'two');
      expect(utf8.decode(await pair.resp.decryptMessage(enc0.wire)), 'zero');
      expect(utf8.decode(await pair.resp.decryptMessage(enc1.wire)), 'one');
      expect(pair.resp.recvCounter, 2);
      expect(pair.resp.skippedCounters, isEmpty);
    });

    test('replay after in-order decrypt is rejected', () async {
      final pair = await _pairedSessions();
      final enc = await pair.init.encryptMessage(utf8.encode('once'));

      await pair.resp.decryptMessage(enc.wire);
      expect(
        () => pair.resp.decryptMessage(enc.wire),
        throwsA(isA<StateError>()),
      );
    });

    test('replay after late fill is rejected', () async {
      final pair = await _pairedSessions();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      final enc1 = await pair.init.encryptMessage(utf8.encode('one'));

      await pair.resp.decryptMessage(enc1.wire);
      await pair.resp.decryptMessage(enc0.wire);
      expect(
        () => pair.resp.decryptMessage(enc0.wire),
        throwsA(isA<StateError>()),
      );
    });

    test('gap larger than maxSkip is rejected without state change', () async {
      final pair = await _pairedSessions();
      pair.init.sendCounter = CryptoConstants.ratchetMaxSkip + 2;
      final enc = await pair.init.encryptMessage(utf8.encode('too far'));

      expect(
        () => pair.resp.decryptMessage(enc.wire),
        throwsA(
          predicate(
            (e) => e is StateError && e.message == 'Counter too far ahead',
          ),
        ),
      );
      expect(pair.resp.recvCounter, -1);
      expect(pair.resp.skippedCounters, isEmpty);
    });

    test('skipped counters survive json round trip', () async {
      final pair = await _pairedSessions();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      final enc1 = await pair.init.encryptMessage(utf8.encode('one'));

      await pair.resp.decryptMessage(enc1.wire);
      expect(pair.resp.skippedCounters, {0});

      final restored = RatchetSession.fromJson(pair.resp.toJson());
      final plain0 = await restored.decryptMessage(enc0.wire);
      expect(utf8.decode(plain0), 'zero');
      expect(restored.recvCounter, 1);
      expect(restored.skippedCounters, isEmpty);
    });
  });
}
