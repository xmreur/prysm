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
    final usedOtpB64 = base64Encode(bobBundle.oneTimePreKeyPublic.bytes);

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

  test('handshake without oneTimePreKey falls back to pool.first and consumes it',
      () async {
    final alice = await IdentityKeyPair.generate();
    final bob = await IdentityKeyPair.generate();
    final alicePub = await _publicKeys(alice);
    final bobPub = await _publicKeys(bob);
    const aliceOnion = 'alice.peer.onion';

    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final bundleOtpB64 = base64Encode(bobBundle.oneTimePreKeyPublic.bytes);

    final ephemeral = await X25519().newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await PrekeyBundle.sharedSecretAsInitiator(
      local: alice,
      peer: bobPub,
      peerBundle: bobBundle,
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

    final pool = jsonDecode(
      (await CryptoKeyStore.read(PrekeyBundle.storageOneTimePreKeyPool))!,
    ) as List;
    expect((pool.first as Map)['pub'], isNot(bundleOtpB64));
    expect(
      pool.map((e) => (e as Map)['pub']),
      isNot(contains(bundleOtpB64)),
    );
  });

  test('commitOneTimePreKeyConsumption is idempotent', () async {
    final bob = await IdentityKeyPair.generate();
    final bobBundle = await PrekeyBundle.generate(bob, persist: true);
    final otp = bobBundle.oneTimePreKeyPublic;

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
}
