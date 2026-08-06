import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
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

  /// Null when the one-time prekey pool has no servable entry (all entries
  /// reserved by deliveries or claimed by in-flight handshakes): the bundle
  /// is then served without an OTK. X3DH without a one-time prekey is valid;
  /// the initiator simply skips the DH4 term.
  final SimplePublicKey? oneTimePreKeyPublic;

  static const String storageSignedPreKeyPrivate = 'SIGNED_PREKEY_PRIVATE_V2';
  static const String storageOneTimePreKeyPrivate = 'ONETIME_PREKEY_PRIVATE_V2';
  static const String storageOneTimePreKeyPool = 'ONETIME_PREKEY_POOL_V2';

  static const int _oneTimePoolSize = 16;
  static const int _oneTimeReplenishThreshold = 4;

  /// X25519 public keys and seeds are 32 bytes; a persisted pool entry of any
  /// other length cannot produce a key pair.
  static const int _x25519KeyBytes = 32;

  /// How long a delivered one-time prekey stays reserved before it becomes
  /// servable again: a handshake that never arrives must not burn the key
  /// permanently. Also bounds the in-use mark left by a lookup whose
  /// handshake never completed (e.g. after a process crash).
  static const Duration _reservationTtl = Duration(minutes: 30);

  static final X25519 _x25519 = X25519();

  static final Mutex _poolMutex = Mutex();

  static DateTime Function() _now = DateTime.now;

  /// Test seam: replaces the clock used for reservation expiry. Mirrors the
  /// `now ?? DateTime.now` injection convention used elsewhere in the repo.
  @visibleForTesting
  static void setClockForTest(DateTime Function()? clock) {
    _now = clock ?? DateTime.now;
  }

  static bool _isUnexpired(String? atMillis, DateTime now) {
    if (atMillis == null) return false;
    // The persisted pool is untrusted input (restored backups, foreign
    // stores): a timestamp that cannot be parsed counts as expired, so the
    // entry is servable and the pool self-heals via [_ensureOneTimePool].
    final atMillisValue = int.tryParse(atMillis);
    if (atMillisValue == null) return false;
    final at = DateTime.fromMillisecondsSinceEpoch(atMillisValue);
    final elapsed = now.difference(at);
    // A mark in the future (restored backup, clock moved backwards) must
    // not pin the entry out of service until the wall clock catches up:
    // treat it as expired.
    if (elapsed.isNegative) return false;
    return elapsed < _reservationTtl;
  }

  /// Whether the entry is tied to a delivered bundle whose reservation has
  /// not yet expired.
  static bool _isReserved(Map<String, String> entry, DateTime now) =>
      _isUnexpired(entry['reservedAt'], now);

  /// Whether the entry is claimed by an in-flight handshake lookup whose
  /// mark has not yet expired.
  static bool _isInUse(Map<String, String> entry, DateTime now) =>
      _isUnexpired(entry['inUseAt'], now);

  /// Servable by [_nextOneTimePublic]: neither delivery-reserved nor claimed
  /// by an in-flight handshake.
  static bool _isAvailable(Map<String, String> entry, DateTime now) =>
      !_isReserved(entry, now) && !_isInUse(entry, now);

  static Future<PrekeyBundle> generate(
    IdentityKeyPair identity, {
    bool persist = true,
  }) async {
    final SimplePublicKey? oneTimePreKeyPublic;
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
    await _poolMutex.protect(() async {
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
    });
  }

  static Future<List<Map<String, String>>> _readOneTimePool() async {
    final raw = await CryptoKeyStore.read(storageOneTimePreKeyPool);
    if (raw == null || raw.isEmpty) return [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Same stance as the per-entry filter below: a blob that is not JSON
      // at all must not brick unlock or /profile. The empty pool degrades
      // to a fresh refill by [_ensureOneTimePool].
      return [];
    }
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .where((e) {
          // The persisted pool is untrusted input (a corrupted or foreign
          // store must not brick unlock or /profile): entries that are not
          // maps of strings, that lack pub/priv, or whose pub/priv are not
          // a decodable base64 X25519 key of the right length are dropped
          // instead of throwing. Silent skipping is safe because
          // [_ensureOneTimePool] replaces a dropped entry with a fresh key.
          if (!e.entries.every((en) => en.key is String && en.value is String)) {
            return false;
          }
          final pub = e['pub'];
          final priv = e['priv'];
          if (pub is! String || priv is! String) return false;
          try {
            // Length matters as much as decodability: a truncated seed would
            // reach newKeyPairFromSeed and throw ArgumentError there, which
            // no caller handles, leaving an entry that poisons every
            // handshake naming it.
            return base64Decode(pub).length == _x25519KeyBytes &&
                base64Decode(priv).length == _x25519KeyBytes;
          } on FormatException {
            return false;
          }
        })
        .map((e) => Map<String, String>.from(e.cast<String, String>()))
        .toList();
  }

  static Future<void> _writeOneTimePool(List<Map<String, String>> pool) async {
    await CryptoKeyStore.write(storageOneTimePreKeyPool, jsonEncode(pool));
  }

  static Future<void> _ensureOneTimePool(IdentityKeyPair identity) async {
    await _poolMutex.protect(() async {
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
    });
  }

  /// Serves the first non-reserved one-time prekey and marks it reserved at
  /// delivery time, so a later [loadStored] serves a different entry. When
  /// every entry is reserved (or claimed by an in-flight handshake), returns
  /// null: the caller serves the bundle without an OTK (X3DH without a
  /// one-time prekey) instead of failing, so [loadStored] can never throw for
  /// reservation exhaustion. The reservation expires after [_reservationTtl]
  /// and the entry becomes servable again.
  static Future<SimplePublicKey?> _nextOneTimePublic() {
    return _poolMutex.protect(() async {
      final pool = await _readOneTimePool();
      if (pool.isEmpty) {
        return null;
      }
      final now = _now();
      final index = pool.indexWhere((e) => _isAvailable(e, now));
      if (index < 0) {
        // All entries are reserved or in use: serve without an OTK.
        return null;
      }
      final entry = pool[index];
      entry['reservedAt'] = '${now.millisecondsSinceEpoch}';
      await _writeOneTimePool(pool);
      final pubBytes = base64Decode(entry['pub']!);
      return SimplePublicKey(pubBytes, type: KeyPairType.x25519);
    });
  }

    /// Non-destructive lookup of a specific one-time prekey private key: the
  /// requested public key must resolve to exactly one pool entry or the
  /// lookup fails (unknown or already claimed by an in-flight handshake).
  /// There is no fallback to "first servable entry": a handshake without an
  /// OTK never reaches this method, so absence of an OTK means no DH4 on
  /// both sides. The pool entry is only removed by
  /// [commitOneTimePreKeyConsumption] once the handshake message has been
  /// successfully decrypted. The resolved entry is marked in-use so that two
  /// concurrent handshakes cannot both resolve it; [releaseOneTimePreKey]
  /// clears the mark when a handshake fails.
  static Future<(KeyPair, SimplePublicKey)?> _lookupOneTimePreKey(
    SimplePublicKey requestedPublic,
  ) {
    return _poolMutex.protect(() async {
      final pool = await _readOneTimePool();
      if (pool.isEmpty) return null;
      final now = _now();
      final pubB64 = base64Encode(requestedPublic.bytes);
      final index = pool.indexWhere((e) => e['pub'] == pubB64);
      if (index >= 0 && _isInUse(pool[index], now)) {
        // Already claimed by another in-flight handshake.
        return null;
      }
      if (index < 0) return null;
      final entry = pool[index];
      entry['inUseAt'] = '${now.millisecondsSinceEpoch}';
      await _writeOneTimePool(pool);
      final keyPair = await _x25519.newKeyPairFromSeed(
        base64Decode(entry['priv']!),
      );
      final public = SimplePublicKey(
        base64Decode(entry['pub']!),
        type: KeyPairType.x25519,
      );
      return (keyPair, public);
    });
  }

  /// Clears the in-use mark set by [_lookupOneTimePreKey] when a handshake
  /// fails before [commitOneTimePreKeyConsumption] ran, so the entry becomes
  /// resolvable again. No-op when the entry is absent or was never marked.
  static Future<void> releaseOneTimePreKey(SimplePublicKey public) {
    return _poolMutex.protect(() async {
      final pool = await _readOneTimePool();
      final pubB64 = base64Encode(public.bytes);
      final index = pool.indexWhere((e) => e['pub'] == pubB64);
      if (index < 0 || pool[index]['inUseAt'] == null) return;
      pool[index].remove('inUseAt');
      await _writeOneTimePool(pool);
    });
  }

  /// Removes a one-time prekey from the persistent pool only after its
  /// handshake message has been successfully decrypted, then replenishes the
  /// pool below the threshold. Idempotent: no-op if already consumed.
  static Future<void> commitOneTimePreKeyConsumption(
    SimplePublicKey public,
  ) {
    return _poolMutex.protect(() async {
      final pool = await _readOneTimePool();
      final pubB64 = base64Encode(public.bytes);
      final before = pool.length;
      pool.removeWhere((e) => e['pub'] == pubB64);
      if (pool.length == before) return;
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
      }
      await _writeOneTimePool(pool);
    });
  }

  Map<String, dynamic> toJson() {
    final oneTime = oneTimePreKeyPublic;
    return {
      'crypto': CryptoConstants.cryptoVersion,
      'signedPreKey': base64Encode(signedPreKeyPublic.bytes),
      'signedPreKeySig': base64Encode(signedPreKeySignature),
      'oneTimePreKey': oneTime == null ? null : base64Encode(oneTime.bytes),
    };
  }

  static PrekeyBundle fromJson(Map<String, dynamic> json) {
    if (json['crypto'] != CryptoConstants.cryptoVersion) {
      throw FormatException('Unsupported prekey bundle version');
    }
    final signedBytes = base64Decode(json['signedPreKey'] as String);
    final oneTimeRaw = json['oneTimePreKey'] as String?;
    final oneTimePublic = oneTimeRaw == null
        ? null
        : SimplePublicKey(
            base64Decode(oneTimeRaw),
            type: KeyPairType.x25519,
          );
    return PrekeyBundle(
      signedPreKeyPublic: SimplePublicKey(
        signedBytes,
        type: KeyPairType.x25519,
      ),
      signedPreKeySignature:
          base64Decode(json['signedPreKeySig'] as String),
      oneTimePreKeyPublic: oneTimePublic,
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

  /// X3DH-style shared secret for session bootstrap (initiator side). When
  /// [peerBundle] carries no one-time prekey (degraded bundle served with an
  /// exhausted reservation pool), the DH4 term is omitted: X3DH without an
  /// OTK is valid.
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
    final materialBytes = <int>[
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
    ];
    final oneTime = peerBundle.oneTimePreKeyPublic;
    if (oneTime != null) {
      final dh4 = await _x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: oneTime,
      );
      materialBytes.addAll(await dh4.extractBytes());
    }
    return Uint8List.fromList(materialBytes);
  }

  /// Responder-side shared secret using stored one-time prekey.
  /// Non-destructive: the used one-time prekey remains in the pool until
  /// [commitOneTimePreKeyConsumption] is called after a successful decrypt.
  ///
  /// The handshake's OTK presence is unambiguous. A null
  /// [usedOneTimePreKeyPublic] means the initiator was served a bundle
  /// without an OTK (degraded bundle from [loadStored]) and omitted the DH4
  /// term: the responder derives DH1||DH2||DH3 and touches the pool not at
  /// all, so a pool that became servable again in between can never make the
  /// two sides disagree. A requested OTK must resolve to exactly that pool
  /// entry or derivation fails (unknown or already claimed by a concurrent
  /// handshake).
  static Future<({Uint8List material, SimplePublicKey? usedOneTimePreKeyPublic})?>
      sharedSecretAsResponder({
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

    KeyPair? oneTimePreKey;
    SimplePublicKey? oneTimePublic;
    final requestedOneTime = usedOneTimePreKeyPublic;
    if (requestedOneTime != null) {
      final lookup = await _lookupOneTimePreKey(requestedOneTime);
      if (lookup == null) {
        // The requested OTK is unknown or claimed by an in-flight handshake:
        // derivation must fail (exactly one of the concurrent handshakes wins).
        return null;
      }
      (oneTimePreKey, oneTimePublic) = lookup;
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
    final materialBytes = <int>[
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
    ];
    final oneTime = oneTimePreKey;
    if (oneTime != null) {
      final dh4 = await _x25519.sharedSecretKey(
        keyPair: oneTime,
        remotePublicKey: initiatorEphemeralPublic,
      );
      materialBytes.addAll(await dh4.extractBytes());
    }
    return (
      material: Uint8List.fromList(materialBytes),
      usedOneTimePreKeyPublic: oneTimePublic,
    );
  }
}
