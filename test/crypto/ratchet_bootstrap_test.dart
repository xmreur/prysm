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

  test('handshake without oneTimePreKey falls back to the first servable entry and consumes it',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final bundleOtpB64 = base64Encode(bobBundle.oneTimePreKeyPublic!.bytes);

    // The responder resolves the first servable entry (the bundle OTK is
    // reserved at delivery and skipped). Derive the X3DH material with that
    // entry, as the initiator of a legacy fallback handshake would.
    final poolBefore = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    final fallbackEntry = poolBefore
        .cast<Map>()
        .firstWhere((e) => e['reservedAt'] == null && e['inUseAt'] == null);
    final fallbackOtpB64 = fallbackEntry['pub'] as String;
    final fallbackBundle = PrekeyBundle(
      signedPreKeyPublic: bobBundle.signedPreKeyPublic,
      signedPreKeySignature: bobBundle.signedPreKeySignature,
      oneTimePreKeyPublic: SimplePublicKey(
        base64Decode(fallbackOtpB64),
        type: KeyPairType.x25519,
      ),
    );

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: fallbackBundle,
      ephemeral: ephemeral,
    );
    final initSession = await RatchetSession.initializeV3AsInitiator(shared);
    final handshake = {'ephemeralPub': base64Encode(ephemeralPub.bytes)};
    final result = await initSession.encryptMessage(
      utf8.encode('fallback'),
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
    expect(plain, 'fallback');

    final after = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    final beforePubs = poolBefore.map((e) => (e as Map)['pub']).toSet();
    final afterPubs = after.map((e) => (e as Map)['pub']).toSet();
    final consumed = beforePubs.difference(afterPubs);
    expect(consumed, {fallbackOtpB64});
    // The delivered OTK stays in the pool (reserved, not consumed).
    expect(afterPubs, contains(bundleOtpB64));
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
}
