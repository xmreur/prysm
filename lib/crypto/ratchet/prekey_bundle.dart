import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';

/// X3DH-style signed prekey bundle published on `/profile`.
class PrekeyBundle {
  PrekeyBundle({
    required this.signedPreKeyPublic,
    required this.signedPreKeySignature,
    required this.oneTimePreKeyPublic,
  });

  final SimplePublicKey signedPreKeyPublic;
  final List<int> signedPreKeySignature;
  final SimplePublicKey oneTimePreKeyPublic;

  static const String storageSignedPreKeyPrivate = 'SIGNED_PREKEY_PRIVATE_V2';
  static const String storageOneTimePreKeyPrivate = 'ONETIME_PREKEY_PRIVATE_V2';
  static const String storageOneTimePreKeyPool = 'ONETIME_PREKEY_POOL_V2';

  static const int _oneTimePoolSize = 16;
  static const int _oneTimeReplenishThreshold = 4;

  static final X25519 _x25519 = X25519();

  static Future<PrekeyBundle> generate(
    IdentityKeyPair identity, {
    bool persist = true,
  }) async {
    final SimplePublicKey oneTimePreKeyPublic;
    if (persist) {
      await _ensureOneTimePool(identity);
      oneTimePreKeyPublic = await _nextOneTimePublic();
    } else {
      final oneTime = await _x25519.newKeyPair();
      oneTimePreKeyPublic = await oneTime.extractPublicKey();
    }
    final signedPreKey = await _x25519.newKeyPair();
    final signedPreKeyPublic = await signedPreKey.extractPublicKey();
    final signedPreKeyPrivate = await signedPreKey.extractPrivateKeyBytes();

    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    final signature = await identity.sign(signPayload);

    if (persist) {
      await CryptoKeyStore.write(
        storageSignedPreKeyPrivate,
        base64Encode(signedPreKeyPrivate),
      );
    }

    return PrekeyBundle(
      signedPreKeyPublic: signedPreKeyPublic,
      signedPreKeySignature: signature.bytes,
      oneTimePreKeyPublic: oneTimePreKeyPublic,
    );
  }

  static Future<PrekeyBundle?> loadStored(IdentityKeyPair identity) async {
    await _migrateLegacyOneTimeKey();
    final signedPrivateB64 =
        await CryptoKeyStore.read(storageSignedPreKeyPrivate);
    if (signedPrivateB64 == null) {
      return generate(identity);
    }

    await _ensureOneTimePool(identity);

    final signedPrivate = base64Decode(signedPrivateB64);
    final signedPreKey = await _x25519.newKeyPairFromSeed(signedPrivate);
    final signedPreKeyPublic = await signedPreKey.extractPublicKey();
    final oneTimePreKeyPublic = await _nextOneTimePublic();
    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    final signature = await identity.sign(signPayload);

    return PrekeyBundle(
      signedPreKeyPublic: signedPreKeyPublic,
      signedPreKeySignature: signature.bytes,
      oneTimePreKeyPublic: oneTimePreKeyPublic,
    );
  }

  static Future<void> _migrateLegacyOneTimeKey() async {
    final legacy = await CryptoKeyStore.read(storageOneTimePreKeyPrivate);
    if (legacy == null) return;
    final poolRaw = await CryptoKeyStore.read(storageOneTimePreKeyPool);
    if (poolRaw != null && poolRaw.isNotEmpty) {
      await CryptoKeyStore.delete(storageOneTimePreKeyPrivate);
      return;
    }
    final private = base64Decode(legacy);
    final keyPair = await _x25519.newKeyPairFromSeed(private);
    final public = await keyPair.extractPublicKey();
    await _writeOneTimePool([
      {
        'pub': base64Encode(public.bytes),
        'priv': legacy,
      },
    ]);
    await CryptoKeyStore.delete(storageOneTimePreKeyPrivate);
  }

  static Future<List<Map<String, String>>> _readOneTimePool() async {
    final raw = await CryptoKeyStore.read(storageOneTimePreKeyPool);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => Map<String, String>.from(e.cast<String, String>()))
        .toList();
  }

  static Future<void> _writeOneTimePool(List<Map<String, String>> pool) async {
    await CryptoKeyStore.write(storageOneTimePreKeyPool, jsonEncode(pool));
  }

  static Future<void> _ensureOneTimePool(IdentityKeyPair identity) async {
    var pool = await _readOneTimePool();
    while (pool.length < _oneTimePoolSize) {
      final oneTime = await _x25519.newKeyPair();
      final oneTimePublic = await oneTime.extractPublicKey();
      final oneTimePrivate = await oneTime.extractPrivateKeyBytes();
      pool.add({
        'pub': base64Encode(oneTimePublic.bytes),
        'priv': base64Encode(oneTimePrivate),
      });
    }
    await _writeOneTimePool(pool);
  }

  static Future<SimplePublicKey> _nextOneTimePublic() async {
    final pool = await _readOneTimePool();
    if (pool.isEmpty) {
      throw StateError('One-time prekey pool is empty');
    }
    final entry = pool.first;
    final pubBytes = base64Decode(entry['pub']!);
    return SimplePublicKey(pubBytes, type: KeyPairType.x25519);
  }

  static Future<KeyPair?> _consumeOneTimePrivateForPublic(
    SimplePublicKey public,
  ) async {
    final pool = await _readOneTimePool();
    final pubB64 = base64Encode(public.bytes);
    final index = pool.indexWhere((e) => e['pub'] == pubB64);
    if (index < 0) return null;
    final entry = pool.removeAt(index);
    await _writeOneTimePool(pool);
  if (pool.length < _oneTimeReplenishThreshold) {
      while (pool.length < _oneTimePoolSize) {
        final oneTime = await _x25519.newKeyPair();
        final oneTimePublic = await oneTime.extractPublicKey();
        final oneTimePrivate = await oneTime.extractPrivateKeyBytes();
        pool.add({
          'pub': base64Encode(oneTimePublic.bytes),
          'priv': base64Encode(oneTimePrivate),
        });
      }
      await _writeOneTimePool(pool);
    }
    return _x25519.newKeyPairFromSeed(base64Decode(entry['priv']!));
  }

  Map<String, dynamic> toJson() => {
        'crypto': CryptoConstants.cryptoVersion,
        'signedPreKey': base64Encode(signedPreKeyPublic.bytes),
        'signedPreKeySig': base64Encode(signedPreKeySignature),
        'oneTimePreKey': base64Encode(oneTimePreKeyPublic.bytes),
      };

  static PrekeyBundle fromJson(Map<String, dynamic> json) {
    if (json['crypto'] != CryptoConstants.cryptoVersion) {
      throw FormatException('Unsupported prekey bundle version');
    }
    final signedBytes = base64Decode(json['signedPreKey'] as String);
    final oneTimeBytes = base64Decode(json['oneTimePreKey'] as String);
    return PrekeyBundle(
      signedPreKeyPublic: SimplePublicKey(
        signedBytes,
        type: KeyPairType.x25519,
      ),
      signedPreKeySignature:
          base64Decode(json['signedPreKeySig'] as String),
      oneTimePreKeyPublic: SimplePublicKey(
        oneTimeBytes,
        type: KeyPairType.x25519,
      ),
    );
  }

  static Future<PrekeyBundle> parseVerified(
    Map<String, dynamic> json,
    IdentityPublicKeys identity,
  ) async {
    final bundle = fromJson(json);
    if (!await bundle.verifySignature(identity)) {
      throw const FormatException('Invalid prekey bundle signature');
    }
    return bundle;
  }

  Future<bool> verifySignature(IdentityPublicKeys identity) async {
    final signPayload = utf8.encode(
      'prysm-prekey:${base64Encode(signedPreKeyPublic.bytes)}',
    );
    return Ed25519().verify(
      signPayload,
      signature: Signature(
        signedPreKeySignature,
        publicKey: identity.signPublic,
      ),
    );
  }

  /// X3DH-style shared secret for session bootstrap (initiator side).
  static Future<Uint8List> sharedSecretAsInitiator({
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    required PrekeyBundle peerBundle,
    required KeyPair ephemeral,
  }) async {
    final dh1 = await _x25519.sharedSecretKey(
      keyPair: local.agreeKeyPair,
      remotePublicKey: peerBundle.signedPreKeyPublic,
    );
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peer.agreePublic,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerBundle.signedPreKeyPublic,
    );
    final dh4 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerBundle.oneTimePreKeyPublic,
    );
    final material = Uint8List.fromList([
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
      ...await dh4.extractBytes(),
    ]);
    return material;
  }

  /// Responder-side shared secret using stored one-time prekey.
  static Future<Uint8List?> sharedSecretAsResponder({
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    required SimplePublicKey initiatorEphemeralPublic,
    SimplePublicKey? usedOneTimePreKeyPublic,
  }) async {
    final signedPrivateB64 =
        await CryptoKeyStore.read(storageSignedPreKeyPrivate);
    if (signedPrivateB64 == null) {
      return null;
    }

    final signedPreKey = await _x25519.newKeyPairFromSeed(
      base64Decode(signedPrivateB64),
    );

    final oneTimePublic = usedOneTimePreKeyPublic ?? await _nextOneTimePublic();
    final oneTimePreKey = await _consumeOneTimePrivateForPublic(oneTimePublic);
    if (oneTimePreKey == null) {
      return null;
    }

    final dh1 = await _x25519.sharedSecretKey(
      keyPair: signedPreKey,
      remotePublicKey: peer.agreePublic,
    );
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: local.agreeKeyPair,
      remotePublicKey: initiatorEphemeralPublic,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: signedPreKey,
      remotePublicKey: initiatorEphemeralPublic,
    );
    final dh4 = await _x25519.sharedSecretKey(
      keyPair: oneTimePreKey,
      remotePublicKey: initiatorEphemeralPublic,
    );
    return Uint8List.fromList([
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
      ...await dh4.extractBytes(),
    ]);
  }
}
