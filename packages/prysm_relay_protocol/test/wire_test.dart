import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:test/test.dart';

const _relayOnion =
    'k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion';
const _ownerOnion =
    'x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion';
final _relayFpr = 'a' * 64;
final _ownerFpr = 'b' * 64;
final _deposit = 'c' * 64;

void main() {
  final ed25519 = Ed25519();

  group('canonical json', () {
    test('key order does not change the signed bytes', () {
      final a = canonicalJson({'b': 1, 'a': {'d': 2, 'c': 3}});
      final b = canonicalJson({'a': {'c': 3, 'd': 2}, 'b': 1});
      expect(a, b);
      expect(a, '{"a":{"c":3,"d":2},"b":1}');
    });

    test('a changed value changes the bytes', () {
      expect(canonicalJson({'a': 1}), isNot(canonicalJson({'a': 2})));
    });
  });

  group('contract', () {
    RelayContract build() => RelayContract(
          version: 1,
          relayFingerprint: _relayFpr,
          relayOnion: _relayOnion,
          ownerFingerprint: _ownerFpr,
          ownerOnion: _ownerOnion,
          tenancy: RelayTenancy.private,
          limits: RelayLimits.privateDefaults,
          issuedAt: 1789200000000,
        );

    test('survives a json round trip', () {
      final signed = build().withSignature('sig');
      final decoded = RelayContract.fromJson(
        jsonDecode(jsonEncode(signed.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.limits, RelayLimits.privateDefaults);
      expect(decoded.ownerOnion, _ownerOnion);
      expect(decoded.overflow, 'reject');
      expect(decoded.sig, 'sig');
    });

    test('a relay signature verifies, and stops verifying if a limit is edited',
        () async {
      final keyPair = await ed25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final contract = build();
      final signed =
          contract.withSignature(await RelaySigning.sign(contract.signingBytes(), keyPair));

      expect(await signed.verify(publicKey.bytes), isTrue);

      final tamperedJson = signed.toJson();
      (tamperedJson['limits'] as Map<String, dynamic>)['maxTenantBytes'] =
          1024 * 1024 * 1024;
      final tampered = RelayContract.fromJson(tamperedJson);
      expect(await tampered.verify(publicKey.bytes), isFalse);
    });

    test('an unknown protocol id is refused outright', () {
      final json = build().toJson()..['protocol'] = 'prysm-relay/2';
      expect(() => RelayContract.fromJson(json), throwsA(isA<RelayError>()));
    });

    test('unknown keys inside limits are ignored, not fatal', () {
      final json = build().toJson();
      (json['limits'] as Map<String, dynamic>)['someFutureKnob'] = 7;
      expect(RelayContract.fromJson(json).limits, RelayLimits.privateDefaults);
    });

    test('an unsupported overflow policy is refused', () {
      final json = build().toJson()..['overflow'] = 'drop-oldest';
      expect(() => RelayContract.fromJson(json), throwsA(isA<RelayError>()));
    });

    test('a missing overflow reads as reject', () {
      final json = build().toJson()..remove('overflow');
      expect(RelayContract.fromJson(json).overflow, 'reject');
    });
  });

  group('advertisement', () {
    RelayAdvertisement build() => RelayAdvertisement(
          issuedAt: 1789200000000,
          expiresAt: 1791792000000,
          relays: [
            RelayEndpoint(
              onion: _relayOnion,
              deposit: _deposit,
              maxItemBytes: 1048576,
            ),
          ],
        );

    test('a cached advertisement stays verifiable offline', () async {
      final keyPair = await ed25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final advert = build();
      final signed = advert.withSignature(
        await RelaySigning.sign(advert.signingBytes(_ownerFpr), keyPair),
      );

      final cached = jsonEncode(signed.toJson());
      final restored = RelayAdvertisement.fromJson(
        jsonDecode(cached) as Map<String, dynamic>,
      );
      expect(
        await restored.verify(
          ownerFingerprint: _ownerFpr,
          ownerSignPublicKey: publicKey.bytes,
        ),
        isTrue,
      );
      expect(restored.preferred!.deposit, _deposit);
    });

    test('swapping the deposit address breaks the signature', () async {
      final keyPair = await ed25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final advert = build();
      final signed = advert.withSignature(
        await RelaySigning.sign(advert.signingBytes(_ownerFpr), keyPair),
      );

      final json = signed.toJson();
      (json['relays'] as List).first['deposit'] = 'd' * 64;
      final forged = RelayAdvertisement.fromJson(json);
      expect(
        await forged.verify(
          ownerFingerprint: _ownerFpr,
          ownerSignPublicKey: publicKey.bytes,
        ),
        isFalse,
      );
    });

    test('editing maxItemBytes or blockSize breaks the signature', () async {
      final keyPair = await ed25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final advert = build();
      final signed = advert.withSignature(
        await RelaySigning.sign(advert.signingBytes(_ownerFpr), keyPair),
      );

      Future<bool> verifyWith(String field, int value) async {
        final json = signed.toJson();
        (json['relays'] as List).first[field] = value;
        return RelayAdvertisement.fromJson(json).verify(
          ownerFingerprint: _ownerFpr,
          ownerSignPublicKey: publicKey.bytes,
        );
      }

      expect(await verifyWith('maxItemBytes', 1), isFalse);
      expect(await verifyWith('blockSize', 4096), isFalse);
    });

    test('expiry is evaluated against the reader clock', () {
      final advert = build();
      expect(advert.expiredAt(DateTime.fromMillisecondsSinceEpoch(1789200000001)), isFalse);
      expect(advert.expiredAt(DateTime.fromMillisecondsSinceEpoch(1791792000000)), isTrue);
    });
  });

  group('limits', () {
    test('a client request is clamped down, never up', () {
      final clamped = RelayLimits.publicDefaults.clamp({
        'maxItemBytes': 64 * 1024 * 1024,
        'itemTtlSeconds': 3600,
      });
      expect(clamped.maxItemBytes, RelayLimits.publicDefaults.maxItemBytes);
      expect(clamped.itemTtlSeconds, 3600);
    });

    test('a nonsense request falls back to the relay ceiling', () {
      final clamped = RelayLimits.publicDefaults.clamp({'maxItemBytes': -1});
      expect(clamped.maxItemBytes, RelayLimits.publicDefaults.maxItemBytes);
    });
  });

  group('errors', () {
    test('a full mailbox is retryable, a rejected one is not', () {
      expect(RelayErrorCode.isRetryable(RelayErrorCode.mailboxFull), isTrue);
      expect(RelayErrorCode.isRetryable(RelayErrorCode.tenantFull), isTrue);
      expect(RelayErrorCode.isRetryable(RelayErrorCode.rateLimited), isTrue);
      expect(RelayErrorCode.isRetryable(RelayErrorCode.mailboxUnknown), isFalse);
      expect(RelayErrorCode.isRetryable(RelayErrorCode.itemTooLarge), isFalse);
    });

    test('a revoked mailbox answers exactly like one that never existed', () {
      expect(
        RelayErrorCode.httpStatus(RelayErrorCode.mailboxUnknown),
        RelayErrorCode.httpStatus(RelayErrorCode.notFound),
      );
    });
  });

  group('auth signing', () {
    test('the same request signed for another path does not verify', () async {
      final keyPair = await ed25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final body = utf8.encode('{"protocol":"prysm-relay/1"}');
      final bytes = RelaySigning.authBytes(
        relayFingerprint: _relayFpr,
        ownerFingerprint: _ownerFpr,
        method: 'post',
        path: RelayProtocol.pathPickup,
        timestampMs: 1789200000000,
        bodySha256Hex: RelaySigning.sha256Hex(body),
      );
      final sig = await RelaySigning.sign(bytes, keyPair);

      final otherPath = RelaySigning.authBytes(
        relayFingerprint: _relayFpr,
        ownerFingerprint: _ownerFpr,
        method: 'post',
        path: RelayProtocol.pathUnpair,
        timestampMs: 1789200000000,
        bodySha256Hex: RelaySigning.sha256Hex(body),
      );
      expect(
        await RelaySigning.verify(
          message: bytes,
          signatureB64: sig,
          ed25519PublicKey: publicKey.bytes,
        ),
        isTrue,
      );
      expect(
        await RelaySigning.verify(
          message: otherPath,
          signatureB64: sig,
          ed25519PublicKey: publicKey.bytes,
        ),
        isFalse,
      );
    });

    test('a stale timestamp is rejected', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1789200000000);
      expect(RelaySigning.freshTimestamp(1789200000000 - 299000, now: now), isTrue);
      expect(RelaySigning.freshTimestamp(1789200000000 - 301000, now: now), isFalse);
      expect(
        () => RelaySigning.requireFresh(1789200000000 - 301000, now: now),
        throwsA(isA<RelayError>()
            .having((e) => e.code, 'code', RelayErrorCode.staleRequest)),
      );
    });
  });

  group('deposit request', () {
    test('a payload that is not sealed is refused', () {
      expect(
        () => RelayDepositRequest.fromJson({
          'protocol': RelayProtocol.id,
          'deposit': _deposit,
          'payload': {'hello': 'world'},
        }),
        throwsA(isA<RelayError>()),
      );
    });

    test('a malformed deposit address is refused', () {
      expect(
        () => RelayDepositRequest.fromJson({
          'protocol': RelayProtocol.id,
          'deposit': 'TOO-SHORT',
          'payload': {'hello': 'world'},
        }),
        throwsA(isA<RelayError>()),
      );
    });
  });
}
