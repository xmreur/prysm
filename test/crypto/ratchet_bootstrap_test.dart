import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// Rewrites the first pool entry through the raw storage seam, clearing any
/// reservation/in-use marks so the mutated entry is deterministically the
/// first servable one.
Future<void> _corruptOneTimePoolEntry(
  Map<String, dynamic> Function(Map<String, dynamic> entry) mutate,
) async {
  final pool = jsonDecode(
    (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
  ) as List;
  final entry = Map<String, dynamic>.from(pool[0] as Map)
    ..remove('reservedAt')
    ..remove('inUseAt');
  pool[0] = mutate(entry);
  await CryptoKeyStore.write(
    PrekeyBundle.storageOneTimePreKeyPool,
    jsonEncode(pool),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
  });

  tearDownAll(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
  });

  setUp(() async {
    CryptoKeyStore.resetInMemoryStorageForTest();
    RatchetService.instance.setPeerRatchetSchemeFetcherForTest(
      (_) async => CryptoConstants.schemeRatchet3,
    );
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await RatchetSessionStore.ensureTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
    await RatchetSessionStore(db).deleteAll();
  });

  tearDown(() {
    RatchetService.instance.setPeerRatchetSchemeFetcherForTest(null);
    DBHelper.setDatabaseForTest(null);
  });

  test('initiator and responder derive matching X3DH material', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();

    final sharedInit = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
      ephemeral: ephemeral,
    );
    final sharedResp = await PrekeyBundle.sharedSecretAsResponder(
      local: bob,
      peer: alicePub,
      initiatorEphemeralPublic: ephemeralPub,
      usedOneTimePreKeyPublic: bobBundle.oneTimePreKeyPublic,
    );

    expect(sharedResp, isNotNull);
    expect(sharedInit, sharedResp!.material);
  });

  test('hkdf derives non-empty key', () async {
    final shared = Uint8List.fromList(List.generate(32, (i) => i));
    final key = await CryptoKdf.hkdf(
      sharedSecret: shared,
      info: utf8.encode('${CryptoConstants.hkdfInfoRatchet}/send/msg/0'),
      salt: utf8.encode('prysm/ratchet/root-salt'),
    );
    final bytes = await key.extractBytes();
    expect(bytes, isNotEmpty);
  });

  test('ratchet session init with fixed shared secret', () async {
    final shared = Uint8List.fromList(List.generate(32, (i) => i));
    final initSession = await RatchetSession.initializeAsInitiator(shared);
    final enc = await initSession.encryptMessage(utf8.encode('x'));
    expect(enc.wire, isNotEmpty);
  });

  test('ratchet sessions encrypt/decrypt after X3DH', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();

    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
      ephemeral: ephemeral,
    );
    final sharedResp = await PrekeyBundle.sharedSecretAsResponder(
      local: bob,
      peer: alicePub,
      initiatorEphemeralPublic: ephemeralPub,
      usedOneTimePreKeyPublic: bobBundle.oneTimePreKeyPublic,
    );
    expect(shared, sharedResp!.material);

    final initSession = await RatchetSession.initializeAsInitiator(shared);
    final respSession =
        await RatchetSession.initializeAsResponder(sharedResp.material);

    final enc = await initSession.encryptMessage(utf8.encode('direct'));
    final plain = await respSession.decryptMessage(enc.wire);
    expect(utf8.decode(plain), 'direct');
  });

  test('ratchet encrypt/decrypt round trip with prekey bootstrap', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';
    const bobOnion = 'bob.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);

    final wire = await RatchetService.instance.encryptText(
      peerId: bobOnion,
      plaintext: 'ratchet hello',
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
    );

    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    expect(envelope['handshake'], isNotNull);
    expect(envelope['scheme'], CryptoConstants.schemeRatchet3);

    final plain = await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: wire,
      local: bob,
      peer: alicePub,
    );
    expect(plain, 'ratchet hello');
  });

  test('second ratchet message without handshake', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';
    const bobOnion = 'bob.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);

    final wire1 = await RatchetService.instance.encryptText(
      peerId: bobOnion,
      plaintext: 'first',
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
    );
    await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: wire1,
      local: bob,
      peer: alicePub,
    );

    final wire2 = await RatchetService.instance.encryptText(
      peerId: bobOnion,
      plaintext: 'second',
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
    );
    expect((jsonDecode(wire2) as Map)['handshake'], isNull);

    final plain2 = await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: wire2,
      local: bob,
      peer: alicePub,
    );
    expect(plain2, 'second');
  });

  test('concurrent encrypts assign unique counters', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final bobPub = await _publicKeys(bob);
    const bobOnion = 'bob.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);

    await RatchetService.instance.encryptText(
      peerId: bobOnion,
      plaintext: 'bootstrap',
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
    );

    const batchSize = 12;
    final wires = await Future.wait(
      List.generate(
        batchSize,
        (i) => RatchetService.instance.encryptText(
          peerId: bobOnion,
          plaintext: 'msg-$i',
          local: alice,
          peer: bobPub,
          peerBundle: bobBundle,
        ),
      ),
    );

    final counters = wires
        .map((w) => (jsonDecode(w) as Map<String, dynamic>)['counter'] as int)
        .toList();
    expect(counters.toSet().length, batchSize);
    expect(counters, containsAll(List.generate(batchSize, (i) => i + 1)));

    final session = await RatchetSessionStore(await DBHelper.database)
        .load(bobOnion);
    expect(session!.sendCounter, batchSize + 1);
  });

  test('failed handshake does not burn the one-time prekey', () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';
    const bobOnion = 'bob.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final usedOtpB64 = base64Encode(bobBundle.oneTimePreKeyPublic!.bytes);

    final goodWire = await RatchetService.instance.encryptText(
      peerId: bobOnion,
      plaintext: 'ratchet hello',
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
    );

    final envelope = jsonDecode(goodWire) as Map<String, dynamic>;
    final cipher = base64Decode(envelope['ciphertext'] as String);
    cipher[0] ^= 0xff;
    envelope['ciphertext'] = base64Encode(cipher);
    final tamperedWire = jsonEncode(envelope);

    await expectLater(
      RatchetService.instance.decryptText(
        peerId: aliceOnion,
        wire: tamperedWire,
        local: bob,
        peer: alicePub,
      ),
      throwsA(anything),
    );

    final poolAfterFailure = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(
      poolAfterFailure.map((e) => (e as Map)['pub']),
      contains(usedOtpB64),
    );

    final plain = await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: goodWire,
      local: bob,
      peer: alicePub,
    );
    expect(plain, 'ratchet hello');

    final poolAfterSuccess = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(
      poolAfterSuccess.map((e) => (e as Map)['pub']),
      isNot(contains(usedOtpB64)),
    );
  });

  test('handshake without oneTimePreKey derives without DH4 and consumes nothing',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final poolBefore = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;

    // Serve the bundle degraded: no OTK, so X3DH skips the DH4 term and the
    // handshake omits oneTimePreKey.
    final otkLessBundle = PrekeyBundle(
      signedPreKeyPublic: bobBundle.signedPreKeyPublic,
      signedPreKeySignature: bobBundle.signedPreKeySignature,
      oneTimePreKeyPublic: null,
    );

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: otkLessBundle,
      ephemeral: ephemeral,
    );
    // 96 bytes = DH1||DH2||DH3, no DH4 term.
    expect(shared.length, 96);

    // The responder must not resolve a pool entry the initiator never used:
    // an OTK-less handshake derives without DH4 and touches the pool not at
    // all.
    final sharedResp = await PrekeyBundle.sharedSecretAsResponder(
      local: bob,
      peer: alicePub,
      initiatorEphemeralPublic: ephemeralPub,
      usedOneTimePreKeyPublic: null,
    );
    expect(sharedResp, isNotNull);
    expect(sharedResp!.usedOneTimePreKeyPublic, isNull);
    expect(sharedResp.material, shared);
    expect(sharedResp.material.length, 96);

    final initSession = await RatchetSession.initializeV3AsInitiator(shared);
    final handshake = {'ephemeralPub': base64Encode(ephemeralPub.bytes)};
    final result = await initSession.encryptMessage(
      utf8.encode('no-otk'),
      handshake: handshake,
    );
    final envelope = jsonDecode(result.wire) as Map<String, dynamic>;
    envelope['handshake'] = handshake;
    final wire = jsonEncode(envelope);

    final plain = await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: wire,
      local: bob,
      peer: alicePub,
    );
    expect(plain, 'no-otk');

    // Nothing consumed, no entry marked in-use: the pool is unchanged by the
    // OTK-less handshake (the delivered OTK stays reserved, not consumed).
    final poolAfter = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(poolAfter, poolBefore);
  });

  test('commitOneTimePreKeyConsumption is idempotent', () async {
    final bob = await IdentityKeyPair.generate();
    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final otp = bobBundle.oneTimePreKeyPublic!;

    await PrekeyBundle.commitOneTimePreKeyConsumption(otp);
    final afterFirst = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;

    await PrekeyBundle.commitOneTimePreKeyConsumption(otp);
    final afterSecond = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;

    expect(afterSecond.length, afterFirst.length);
    expect(
      afterFirst.map((e) => (e as Map)['pub']),
      isNot(contains(base64Encode(otp.bytes))),
    );
  });

  test('two consecutive loadStored deliveries serve distinct one-time prekeys',
      () async {
    final bob = await IdentityKeyPair.generate();
    final first = (await PrekeyBundle.loadStored(bob))!;
    final second = (await PrekeyBundle.loadStored(bob))!;
    expect(
      base64Encode(first.oneTimePreKeyPublic!.bytes),
      isNot(base64Encode(second.oneTimePreKeyPublic!.bytes)),
    );
  });

  test('concurrent handshakes with the same one-time prekey: exactly one succeeds',
      () async {
    final alice1 = await IdentityKeyPair.generate();
    final alice2 = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alice1Pub = await _publicKeys(alice1);
    final alice2Pub = await _publicKeys(alice2);
    final bobPub = await _publicKeys(bob);
    const alice1Onion = 'alice1.peer.onion';
    const alice2Onion = 'alice2.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);

    // Two initiators bootstrap with the SAME one-time prekey.
    Future<String> wireFor(
      IdentityKeyPair local,
      IdentityPublicKeys peer,
    ) async {
      final ephemeral = await X25519().newKeyPair();
      final ephemeralPub = await ephemeral.extractPublicKey();
      final shared = await PrekeyBundle.sharedSecretAsInitiator(
        local: local,
        peer: peer,
        peerBundle: bobBundle,
        ephemeral: ephemeral,
      );
      final initSession = await RatchetSession.initializeV3AsInitiator(shared);
      final handshake = {
        'ephemeralPub': base64Encode(ephemeralPub.bytes),
        'oneTimePreKey': base64Encode(bobBundle.oneTimePreKeyPublic!.bytes),
      };
      final result = await initSession.encryptMessage(
        utf8.encode('race'),
        handshake: handshake,
      );
      final envelope = jsonDecode(result.wire) as Map<String, dynamic>;
      envelope['handshake'] = handshake;
      return jsonEncode(envelope);
    }

    final wire1 = await wireFor(alice1, bobPub);
    final wire2 = await wireFor(alice2, bobPub);

    final outcomes = await Future.wait([
      RatchetService.instance
          .decryptText(
            peerId: alice1Onion,
            wire: wire1,
            local: bob,
            peer: alice1Pub,
          )
          .then((_) => true, onError: (_) => false),
      RatchetService.instance
          .decryptText(
            peerId: alice2Onion,
            wire: wire2,
            local: bob,
            peer: alice2Pub,
          )
          .then((_) => true, onError: (_) => false),
    ]);
    expect(outcomes.where((ok) => ok).length, 1);
  });

  test('all-reserved pool serves a bundle without one-time prekey', () async {
    final bob = await IdentityKeyPair.generate();
    // Pool size is 16; serving 16 bundles reserves every entry.
    final first = (await PrekeyBundle.loadStored(bob))!;
    final served = <String>{base64Encode(first.oneTimePreKeyPublic!.bytes)};
    for (var i = 1; i < 16; i++) {
      final bundle = (await PrekeyBundle.loadStored(bob))!;
      final otp = bundle.oneTimePreKeyPublic;
      expect(otp, isNotNull);
      served.add(base64Encode(otp!.bytes));
    }
    expect(served.length, 16);

    // 17th delivery: every entry is reserved, so the bundle is served
    // WITHOUT a one-time prekey instead of throwing. The signed prekey and
    // its signature are unchanged.
    final degraded = (await PrekeyBundle.loadStored(bob))!;
    expect(degraded.oneTimePreKeyPublic, isNull);
    expect(degraded.signedPreKeyPublic.bytes, first.signedPreKeyPublic.bytes);
    expect(degraded.signedPreKeySignature, first.signedPreKeySignature);
  });

  test('responder handles an OTK-less handshake while the pool is fully reserved',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';

    // Reserve every one-time prekey via delivery.
    for (var i = 0; i < 16; i++) {
      await PrekeyBundle.loadStored(bob);
    }
    // The 17th delivery is a degraded bundle: no one-time prekey.
    final degraded = (await PrekeyBundle.loadStored(bob))!;
    expect(degraded.oneTimePreKeyPublic, isNull);

    // The initiator derives X3DH material without the DH4 (OTK) term and
    // omits oneTimePreKey from the handshake, as the degraded bundle implies.
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: degraded,
      ephemeral: ephemeral,
    );
    final initSession = await RatchetSession.initializeV3AsInitiator(shared);
    final handshake = {'ephemeralPub': base64Encode(ephemeralPub.bytes)};
    final result = await initSession.encryptMessage(
      utf8.encode('degraded'),
      handshake: handshake,
    );
    final envelope = jsonDecode(result.wire) as Map<String, dynamic>;
    envelope['handshake'] = handshake;
    final wire = jsonEncode(envelope);

    final plain = await RatchetService.instance.decryptText(
      peerId: aliceOnion,
      wire: wire,
      local: bob,
      peer: alicePub,
    );
    expect(plain, 'degraded');

    // Nothing was consumed: the pool still holds all 16 reserved entries.
    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
  });

  test('OTK-less responder derives 96 bytes even after reservations expire',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);

    // Exhaust the pool by delivery so the served bundle is degraded (no OTK).
    for (var i = 0; i < 16; i++) {
      await PrekeyBundle.loadStored(bob);
    }
    final degraded = (await PrekeyBundle.loadStored(bob))!;
    expect(degraded.oneTimePreKeyPublic, isNull);

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: degraded,
      ephemeral: ephemeral,
    );
    expect(shared.length, 96);

    // The handshake arrives after the delivery reservations expired: the
    // pool is servable again, which must not resurrect a DH4 term the
    // initiator never derived.
    PrekeyBundle.setClockForTest(
      () => DateTime.now().add(const Duration(minutes: 31)),
    );
    addTearDown(() => PrekeyBundle.setClockForTest(null));

    final sharedResp = await PrekeyBundle.sharedSecretAsResponder(
      local: bob,
      peer: alicePub,
      initiatorEphemeralPublic: ephemeralPub,
      usedOneTimePreKeyPublic: null,
    );
    expect(sharedResp, isNotNull);
    expect(sharedResp!.usedOneTimePreKeyPublic, isNull);
    expect(sharedResp.material.length, 96);
    expect(sharedResp.material, shared);
  });

  test('degraded bundle survives JSON round trip without an OTK', () async {
    final bob = await IdentityKeyPair.generate();
    // Exhaust the pool by delivery so the next bundle is served degraded.
    for (var i = 0; i < 16; i++) {
      await PrekeyBundle.loadStored(bob);
    }
    final degraded = (await PrekeyBundle.loadStored(bob))!;
    expect(degraded.oneTimePreKeyPublic, isNull);

    // A degraded bundle travels over /profile as JSON and must parse back
    // identically (signed prekey + signature intact, still no OTK).
    final json = degraded.toJson();
    expect(json['oneTimePreKey'], isNull);
    final parsed = PrekeyBundle.fromJson(json);
    expect(parsed.oneTimePreKeyPublic, isNull);
    expect(parsed.signedPreKeyPublic.bytes, degraded.signedPreKeyPublic.bytes);
    expect(parsed.signedPreKeySignature, degraded.signedPreKeySignature);

    final verified = await PrekeyBundle.parseVerified(
      json,
      await _publicKeys(bob),
    );
    expect(verified.oneTimePreKeyPublic, isNull);
  });

  test('delivery reservation expires after 30 minutes (injected clock)',
      () async {
    final bob = await IdentityKeyPair.generate();
    final first = (await PrekeyBundle.loadStored(bob))!;
    final second = (await PrekeyBundle.loadStored(bob))!;
    expect(
      base64Encode(first.oneTimePreKeyPublic!.bytes),
      isNot(base64Encode(second.oneTimePreKeyPublic!.bytes)),
    );

    PrekeyBundle.setClockForTest(
      () => DateTime.now().add(const Duration(minutes: 31)),
    );
    addTearDown(() => PrekeyBundle.setClockForTest(null));

    final third = (await PrekeyBundle.loadStored(bob))!;
    // The first reservation expired: its entry is servable again.
    expect(
      base64Encode(third.oneTimePreKeyPublic!.bytes),
      base64Encode(first.oneTimePreKeyPublic!.bytes),
    );
  });

  test('corrupt pool with non-numeric reservedAt still serves a bundle',
      () async {
    final bob = await IdentityKeyPair.generate();
    await PrekeyBundle.generate(bob, persist: true);
    await _corruptOneTimePoolEntry((e) => e..['reservedAt'] = 'not-a-number');

    // Untrusted pool input must not brick loadStored: the unparseable
    // timestamp counts as expired, so the entry is servable and the bundle
    // is delivered normally.
    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    expect(bundle!.oneTimePreKeyPublic, isNotNull);

    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
    expect(
      pool.every((e) => (e as Map).values.every((v) => v is String)),
      isTrue,
    );
  });

  test('corrupt pool with non-string value still serves a bundle', () async {
    final bob = await IdentityKeyPair.generate();
    await PrekeyBundle.generate(bob, persist: true);
    await _corruptOneTimePoolEntry((e) => e..['reservedAt'] = 12345);

    // The malformed entry is dropped at read time and replenished with a
    // fresh key by _ensureOneTimePool.
    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    expect(bundle!.oneTimePreKeyPublic, isNotNull);

    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
    expect(
      pool.every((e) => (e as Map).values.every((v) => v is String)),
      isTrue,
    );
  });

  test('corrupt pool with undecodable pub still serves a bundle', () async {
    final bob = await IdentityKeyPair.generate();
    await PrekeyBundle.generate(bob, persist: true);
    await _corruptOneTimePoolEntry((e) => e..['pub'] = '!!!not-base64!!!');

    // The undecodable entry is dropped at read time and replenished with a
    // fresh key by _ensureOneTimePool.
    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    expect(bundle!.oneTimePreKeyPublic, isNotNull);

    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
    expect(
      pool.map((e) => (e as Map)['pub']),
      isNot(contains('!!!not-base64!!!')),
    );
  });

  test('corrupt pool with a truncated priv still serves a usable bundle',
      () async {
    final bob = await IdentityKeyPair.generate();
    await PrekeyBundle.generate(bob, persist: true);
    // Valid base64, wrong length (31 bytes): decodable, so a decodability
    // check alone would keep it. newKeyPairFromSeed would then throw
    // ArgumentError from inside the handshake path, where nothing catches it,
    // and the entry would poison every handshake naming that public key.
    String? truncatedPub;
    await _corruptOneTimePoolEntry((e) {
      final short = base64Decode(e['priv'] as String).sublist(0, 31);
      truncatedPub = e['pub'] as String;
      return e..['priv'] = base64Encode(short);
    });

    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    final served = bundle!.oneTimePreKeyPublic;
    expect(served, isNotNull);
    expect(base64Encode(served!.bytes), isNot(truncatedPub));

    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
    expect(pool.map((e) => (e as Map)['pub']), isNot(contains(truncatedPub)));
    // Every surviving entry can actually produce a key pair.
    for (final entry in pool.cast<Map>()) {
      expect(base64Decode(entry['priv'] as String).length, 32);
      expect(base64Decode(entry['pub'] as String).length, 32);
    }
  });

  test('corrupt pool with a non-JSON blob still serves a bundle and self-heals',
      () async {
    final bob = await IdentityKeyPair.generate();
    await PrekeyBundle.generate(bob, persist: true);
    // The whole blob is not JSON at all — the worst a corrupted or foreign
    // store can hand us. The decode must degrade to an empty pool instead of
    // throwing, or unlock / GET /profile hard-fail.
    await CryptoKeyStore.write(
      PrekeyBundle.storageOneTimePreKeyPool,
      'not-json{{{',
    );

    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    expect(bundle!.oneTimePreKeyPublic, isNotNull);

    // The pool self-healed: a valid 16-entry pool was written back.
    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect(pool.length, 16);
    expect(
      pool.every((e) => (e as Map).values.every((v) => v is String)),
      isTrue,
    );
  });

  test('pool entry reserved in the future is servable, not pinned', () async {
    final bob = await IdentityKeyPair.generate();
    final first = (await PrekeyBundle.loadStored(bob))!;
    final firstOtpB64 = base64Encode(first.oneTimePreKeyPublic!.bytes);

    // A restored backup or a backwards clock step leaves a mark in the
    // future: it must count as expired, otherwise the entry stays pinned
    // out of service until the wall clock catches up.
    final futureMillis =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    await _corruptOneTimePoolEntry((e) => e..['reservedAt'] = '$futureMillis');

    final bundle = await PrekeyBundle.loadStored(bob);
    expect(bundle, isNotNull);
    // The future-dated entry is the first servable one again.
    expect(base64Encode(bundle!.oneTimePreKeyPublic!.bytes), firstOtpB64);
  });

  test('pool entry marked in-use in the future is still resolvable by the responder',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);

    final bundle = await PrekeyBundle.generate(bob, persist: true);
    final otp = bundle.oneTimePreKeyPublic!;
    final otpB64 = base64Encode(otp.bytes);

    // A future in-use mark must not make _lookupOneTimePreKey refuse the
    // exact key the handshake names (a refused lookup surfaces as a failed
    // derivation / POST /message 500).
    final futureMillis =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    await _corruptOneTimePoolEntry((e) => e..['inUseAt'] = '$futureMillis');

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final sharedResp = await PrekeyBundle.sharedSecretAsResponder(
      local: bob,
      peer: alicePub,
      initiatorEphemeralPublic: ephemeralPub,
      usedOneTimePreKeyPublic: otp,
    );
    expect(sharedResp, isNotNull);
    expect(sharedResp!.usedOneTimePreKeyPublic, isNotNull);
    expect(
      base64Encode(sharedResp.usedOneTimePreKeyPublic!.bytes),
      otpB64,
    );
    // 96 bytes DH1||DH2||DH3 + 32-byte DH4 term.
    expect(sharedResp.material.length, 128);
  });
}
