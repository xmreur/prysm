import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/util/key_manager.dart';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

Future<({RatchetSession init, RatchetSession resp})> _v3Pair() async {
  final shared = Uint8List.fromList(List.generate(32, (i) => i));
  final init = await RatchetSession.initializeV3AsInitiator(shared);
  final resp = await RatchetSession.initializeV3AsResponder(shared);
  return (init: init, resp: resp);
}

void main() {
  group('Ratchet v3 (hash chain)', () {
    test('roundtrip 10 crossed messages initiator<->responder', () async {
      final pair = await _v3Pair();
      for (var i = 0; i < 10; i++) {
        final enc = await pair.init.encryptMessage(utf8.encode('i->r $i'));
        expect(
          utf8.decode(await pair.resp.decryptMessage(enc.wire)),
          'i->r $i',
        );
        final encR = await pair.resp.encryptMessage(utf8.encode('r->i $i'));
        expect(
          utf8.decode(await pair.init.decryptMessage(encR.wire)),
          'r->i $i',
        );
      }
      expect(pair.init.sendCounter, 10);
      expect(pair.init.recvCounter, 9);
      expect(pair.resp.sendCounter, 10);
      expect(pair.resp.recvCounter, 9);
      expect(pair.resp.recvSkippedKeys, isEmpty);
    });

    test('out-of-order 5 then 3 ok, replay of 3 throws', () async {
      final pair = await _v3Pair();
      final wires = <String>[];
      for (var i = 0; i < 6; i++) {
        final enc = await pair.init.encryptMessage(utf8.encode('m$i'));
        wires.add(enc.wire);
      }

      expect(utf8.decode(await pair.resp.decryptMessage(wires[5])), 'm5');
      expect(pair.resp.recvCounter, 5);
      expect(pair.resp.recvSkippedKeys.keys, {0, 1, 2, 3, 4});

      expect(utf8.decode(await pair.resp.decryptMessage(wires[3])), 'm3');
      expect(pair.resp.recvSkippedKeys.keys, {0, 1, 2, 4});

      expect(
        () => pair.resp.decryptMessage(wires[3]),
        throwsA(isA<StateError>()),
      );
    });

    test('gap of 257 is rejected without state change', () async {
      final pair = await _v3Pair();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      expect(utf8.decode(await pair.resp.decryptMessage(enc0.wire)), 'zero');
      expect(pair.resp.recvCounter, 0);

      pair.init.sendCounter = 258; // gap = 258 - (0 + 1) = 257 > maxSkip
      final enc = await pair.init.encryptMessage(utf8.encode('too far'));

      expect(
        () => pair.resp.decryptMessage(enc.wire),
        throwsA(
          predicate(
            (e) => e is StateError && e.message == 'Counter too far ahead',
          ),
        ),
      );
      expect(pair.resp.recvCounter, 0);
      expect(pair.resp.recvSkippedKeys, isEmpty);
    });

    test('forward secrecy: serialized v3 session cannot decrypt message 0',
        () async {
      final pair = await _v3Pair();
      final wires = <String>[];
      for (var i = 0; i < 10; i++) {
        final enc = await pair.init.encryptMessage(utf8.encode('msg $i'));
        wires.add(enc.wire);
        await pair.resp.decryptMessage(enc.wire);
      }
      // Every message delivered in order — nothing skipped, no stash left.
      expect(pair.resp.recvSkippedKeys, isEmpty);

      final json = pair.resp.toJson();
      // Root material must never be persisted for v3 sessions.
      expect(json.containsKey('sharedMaterial'), isFalse);
      expect(json['version'], 3);

      final clone = RatchetSession.fromJson(json);
      expect(
        () => clone.decryptMessage(wires[0]),
        throwsA(isA<StateError>()),
      );
      // The in-memory session is equally unable to rewind.
      expect(
        () => pair.resp.decryptMessage(wires[0]),
        throwsA(isA<StateError>()),
      );
    });

    test('skipped message key is deleted after use', () async {
      final pair = await _v3Pair();
      final enc0 = await pair.init.encryptMessage(utf8.encode('zero'));
      final enc1 = await pair.init.encryptMessage(utf8.encode('one'));

      await pair.resp.decryptMessage(enc1.wire);
      expect(pair.resp.recvSkippedKeys.containsKey(0), isTrue);

      expect(utf8.decode(await pair.resp.decryptMessage(enc0.wire)), 'zero');
      expect(pair.resp.recvSkippedKeys, isEmpty);

      expect(
        () => pair.resp.decryptMessage(enc0.wire),
        throwsA(isA<StateError>()),
      );
    });

    test('v2 legacy session loads from old-format JSON and decrypts',
        () async {
      final shared = Uint8List.fromList(List.generate(32, (i) => i));
      final init = await RatchetSession.initializeAsInitiator(shared);
      final resp = await RatchetSession.initializeAsResponder(shared);
      final enc0 = await init.encryptMessage(utf8.encode('legacy zero'));
      final enc1 = await init.encryptMessage(utf8.encode('legacy one'));

      await resp.decryptMessage(enc1.wire); // late-skips counter 0 (v2 style)
      final json = resp.toJson();
      // Old-format rows carry no 'version' key.
      expect(json.containsKey('version'), isFalse);
      expect(json.containsKey('sharedMaterial'), isTrue);

      final restored = RatchetSession.fromJson(json);
      expect(restored.version, 2);
      expect(utf8.decode(await restored.decryptMessage(enc0.wire)),
          'legacy zero');
      expect(restored.recvCounter, 1);
      expect(restored.skippedCounters, isEmpty);
    });
  });

  group('DirectMessageAuth ratchet-3', () {
    test('recognizes ratchet-3 as a ratchet scheme while locked', () async {
      final alicePub = await _publicKeys(await IdentityKeyPair.generate());
      final wire = jsonEncode({
        'crypto': CryptoConstants.cryptoVersion,
        'scheme': CryptoConstants.schemeRatchet3,
        'nonce': 'abc',
        'ciphertext': 'def',
        'counter': 0,
      });

      final outcome = await DirectMessageAuth.authenticateInboundDirect(
        senderId: 'alice.onion',
        wire: wire,
        type: 'text',
        localUserId: 'bob.onion',
        keyManager: KeyManager(),
        resolveIdentity: (_) async => alicePub,
        fullDecrypt: true,
      );
      // fullDecrypt + locked: an unknown scheme would be rejected; landing on
      // pendingAuth proves the ratchet branch accepted ratchet-3.
      expect(outcome, DirectAuthOutcome.pendingAuth);
    });
  });
}
