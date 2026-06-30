import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/crypto/ratchet/ratchet_service.dart';
import 'package:prysm/models/unlock_type.dart';

/// Manages Prysm v2 identity keys and message encryption.
class KeyManager {
  IdentityKeyPair? _identity;
  IdentityPublicKeys? _cachedPublic;

  bool isCorrupted = false;

  Future<String?> safeRead(String key) => CryptoKeyStore.read(key);

  Future<bool> unlockWithPassphrase(
    String passphrase, {
    required UnlockType type,
  }) async {
    if (!CryptoKeyStore.isValidUnlockSecret(passphrase, type)) return false;

    final encPrivate = await safeRead(CryptoKeyStore.encryptedIdentityKey);
    final publicJson = await safeRead(CryptoKeyStore.publicIdentityKey);
    final saltB64 = await safeRead(CryptoKeyStore.passphraseSaltKey);

    if (encPrivate != null && publicJson != null && saltB64 != null) {
      final identity = await CryptoKeyStore.decryptIdentity(
        passphrase: passphrase,
        encrypted: encPrivate,
        saltB64: saltB64,
      );
      if (identity == null) return false;
      _identity = identity;
      _cachedPublic = IdentityKeyPair.parsePublicJson(
        jsonDecode(publicJson) as Map<String, dynamic>,
      );
      await PrekeyBundle.loadStored(identity);
      return true;
    }

    if (publicJson != null || encPrivate != null || saltB64 != null) {
      isCorrupted = true;
      return false;
    }

    // First setup: generate new identity.
    final identity = await IdentityKeyPair.generate();
    await CryptoKeyStore.persistIdentity(
      passphrase: passphrase,
      identity: identity,
    );
    _identity = identity;
    _cachedPublic = IdentityPublicKeys(
      signPublic: await identity.signPublicKey,
      agreePublic: await identity.agreePublicKey,
      fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
        await identity.toPublicJson(),
      ),
    );
    await PrekeyBundle.loadStored(identity);
    return true;
  }

  /// Backward-compatible alias during UI migration.
  Future<bool> unlockWithPin(String pin, {required UnlockType type}) =>
      unlockWithPassphrase(pin, type: type);

  Future<bool> isPassphraseSet() => CryptoKeyStore.isPassphraseSet();

  Future<bool> isPinSet() => isPassphraseSet();

  Future<bool> passphraseUnlocksStoredKeys(String passphrase) async {
    final encPrivate = await safeRead(CryptoKeyStore.encryptedIdentityKey);
    final saltB64 = await safeRead(CryptoKeyStore.passphraseSaltKey);
    if (encPrivate == null || saltB64 == null) return false;
    final identity = await CryptoKeyStore.decryptIdentity(
      passphrase: passphrase,
      encrypted: encPrivate,
      saltB64: saltB64,
    );
    return identity != null;
  }

  Future<bool> pinUnlocksStoredKeys(String pin) =>
      passphraseUnlocksStoredKeys(pin);

  Future<bool> changePassphrase({
    required String currentPassphrase,
    required String newPassphrase,
    required UnlockType type,
  }) async {
    if (!CryptoKeyStore.isValidUnlockSecret(newPassphrase, type)) return false;

    final encPrivate = await safeRead(CryptoKeyStore.encryptedIdentityKey);
    final saltB64 = await safeRead(CryptoKeyStore.passphraseSaltKey);
    if (encPrivate == null || saltB64 == null) return false;

    IdentityKeyPair identity;
    if (_identity != null) {
      if (!await passphraseUnlocksStoredKeys(currentPassphrase)) return false;
      identity = _identity!;
    } else {
      final unlocked = await CryptoKeyStore.decryptIdentity(
        passphrase: currentPassphrase,
        encrypted: encPrivate,
        saltB64: saltB64,
      );
      if (unlocked == null) return false;
      identity = unlocked;
    }

    await CryptoKeyStore.persistIdentity(
      passphrase: newPassphrase,
      identity: identity,
    );
    _identity = identity;
    _cachedPublic = IdentityPublicKeys(
      signPublic: await identity.signPublicKey,
      agreePublic: await identity.agreePublicKey,
      fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
        await identity.toPublicJson(),
      ),
    );
    return true;
  }

  Future<bool> changePin({
    required String currentPin,
    required String newPin,
  }) =>
      changePassphrase(
        currentPassphrase: currentPin,
        newPassphrase: newPin,
        type: UnlockType.pin,
      );

  Future<void> loadEphemeralKeys() async {
    _identity = await IdentityKeyPair.generate();
    _cachedPublic = IdentityPublicKeys(
      signPublic: await _identity!.signPublicKey,
      agreePublic: await _identity!.agreePublicKey,
      fingerprint: 'ephemeral',
    );
  }

  void lock() {
    _identity = null;
    _cachedPublic = null;
  }

  Future<void> wipeSecureStorage() async {
    await CryptoKeyStore.deleteAll();
    lock();
  }

  IdentityKeyPair get identity {
    if (_identity == null) {
      throw StateError('Keys not initialized. Unlock first.');
    }
    return _identity!;
  }

  bool get isUnlocked => _identity != null;

  Future<IdentityPublicKeys> get publicIdentity async {
    if (_cachedPublic != null) return _cachedPublic!;
    final raw = await safeRead(CryptoKeyStore.publicIdentityKey);
    if (raw == null) throw StateError('Public identity not found');
    return IdentityKeyPair.parsePublicJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  String get publicKeyJson {
    if (_cachedPublic != null) return _cachedPublic!.toJsonString();
    throw StateError('Public identity not loaded');
  }

  /// Stored public identity JSON (safe without private key loaded).
  Future<String?> storedPublicIdentityJson() =>
      safeRead(CryptoKeyStore.publicIdentityKey);

  Future<String> encryptForPeer(
    String message,
    IdentityPublicKeys peer, {
    required String peerId,
    PrekeyBundle? peerPrekey,
  }) async {
    try {
      return await RatchetService.instance.encryptText(
        peerId: peerId,
        plaintext: message,
        local: identity,
        peer: peer,
        peerBundle: peerPrekey,
      );
    } on StateError {
      return CryptoWire.encryptTextForPeer(message, identity, peer.agreePublic);
    }
  }

  Future<String> decryptPeerMessage({
    required String peerId,
    required String wire,
    required IdentityPublicKeys peer,
  }) async {
    return RatchetService.instance.decryptText(
      peerId: peerId,
      wire: wire,
      local: identity,
      peer: peer,
    );
  }

  Future<String> encryptForSelf(String message) async {
    return CryptoWire.encryptTextForSelf(message, identity);
  }

  Future<String> decryptMessage(String encrypted) async {
    return CryptoWire.decryptTextForSelf(encrypted, identity);
  }

  String decryptMyMessage(String encryptedMessage) {
    throw UnsupportedError('Use decryptMessage async');
  }

  Future<Uint8List> decryptBytes(String wire) async {
    return CryptoWire.decryptForSelf(wire, identity);
  }

  Future<Uint8List> decryptMyMessageBytes(String wire) => decryptBytes(wire);

  Future<String> encryptBytesForPeer(
    Uint8List data,
    IdentityPublicKeys peer, {
    String? peerId,
    PrekeyBundle? peerPrekey,
  }) async {
    return CryptoWire.encryptForPeer(data, identity, peer.agreePublic);
  }

  Future<String> encryptBytesForSelf(Uint8List data) async {
    return CryptoWire.encryptForSelf(data, identity);
  }

  Future<String> encryptHybridForPeer(
    String plaintext,
    IdentityPublicKeys peer, {
    required String peerId,
    PrekeyBundle? peerPrekey,
  }) =>
      encryptForPeer(
        plaintext,
        peer,
        peerId: peerId,
        peerPrekey: peerPrekey,
      );

  Future<String> decryptHybridEnvelope(String envelopeJson) async {
    return decryptMessage(envelopeJson);
  }

  static bool isHybridEnvelope(String encrypted) =>
      CryptoEnvelope.isV2(encrypted);

  IdentityPublicKeys importPeerIdentity(String jsonOrPem) {
    final keys = IdentityKeyPair.tryParsePublicJsonString(jsonOrPem);
    if (keys == null) {
      throw FormatException('Expected v2 identity JSON');
    }
    return keys;
  }

  @visibleForTesting
  static Future<Map<String, String>> testEncryptIdentity({
    required String passphrase,
    required IdentityKeyPair identity,
  }) =>
      CryptoKeyStore.testEncryptIdentity(
        passphrase: passphrase,
        identity: identity,
      );

  @visibleForTesting
  static Future<IdentityKeyPair?> testDecryptIdentity({
    required String passphrase,
    required String encrypted,
    required String saltB64,
  }) =>
      CryptoKeyStore.testDecryptIdentity(
        passphrase: passphrase,
        encrypted: encrypted,
        saltB64: saltB64,
      );

  KeyManager();

  factory KeyManager.fromIdentity(IdentityKeyPair identity) {
    final km = KeyManager();
    km._identity = identity;
    return km;
  }
}
