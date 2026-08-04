import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/kdf.dart';

/// Wire-format encrypt/decrypt for 1:1 and wrapped payloads.
class CryptoWire {
  CryptoWire._();

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();

  static String _dmSignPayload({
    required String ephemeralPub,
    required String nonce,
    required String ciphertext,
  }) =>
      '$ephemeralPub|$nonce|$ciphertext';

  /// Ephemeral X25519 + HKDF + AES-GCM for 1:1 text/binary (unsigned).
  static Future<String> encryptForPeer(
    Uint8List plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerAgreePublic,
    );
    final sharedBytes = await shared.extractBytes();
    final aeadKey = await CryptoKdf.hkdf(
      sharedSecret: sharedBytes,
      info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
      salt: ephemeralPublic.bytes,
    );
    final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
    final envelope = CryptoEnvelope.dhAead1(
      ephemeralPublic: Uint8List.fromList(ephemeralPublic.bytes),
      ciphertext: enc.ciphertext,
      nonce: enc.nonce,
    );
    return CryptoEnvelope.encode(envelope);
  }

  static Future<String> encryptTextForPeer(
    String plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) =>
      encryptForPeer(utf8.encode(plaintext), sender, peerAgreePublic);

  /// Signed 1:1 DM: dh-aead-1 core + Ed25519 sender authentication.
  static Future<String> encryptSignedForPeer(
    Uint8List plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: peerAgreePublic,
    );
    final sharedBytes = await shared.extractBytes();
    final aeadKey = await CryptoKdf.hkdf(
      sharedSecret: sharedBytes,
      info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
      salt: ephemeralPublic.bytes,
    );
    final enc = await CryptoAead.encryptAesGcm(plaintext, key: aeadKey);
    final ephemeralPubB64 = base64Encode(ephemeralPublic.bytes);
    final nonceB64 = base64Encode(enc.nonce);
    final ciphertextB64 = base64Encode(enc.ciphertext);
    final signPayload = utf8.encode(
      _dmSignPayload(
        ephemeralPub: ephemeralPubB64,
        nonce: nonceB64,
        ciphertext: ciphertextB64,
      ),
    );
    final signature = await sender.sign(signPayload);
    final envelope = CryptoEnvelope.dmSigned1(
      ephemeralPublic: Uint8List.fromList(ephemeralPublic.bytes),
      ciphertext: enc.ciphertext,
      nonce: enc.nonce,
      signature: signature.bytes,
    );
    return CryptoEnvelope.encode(envelope);
  }

  static Future<String> encryptSignedTextForPeer(
    String plaintext,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) =>
      encryptSignedForPeer(utf8.encode(plaintext), sender, peerAgreePublic);

  static Future<void> _verifyDmSignedEnvelope(
    Map<String, dynamic> envelope,
    IdentityPublicKeys sender,
  ) async {
    final sigRaw = envelope['sig'] as String?;
    if (sigRaw == null) {
      throw const FormatException('Missing DM signature');
    }
    final ephemeralPubB64 = envelope['ephemeralPub'] as String;
    final nonceB64 = envelope['nonce'] as String;
    final ciphertextB64 = envelope['ciphertext'] as String;
    final signPayload = utf8.encode(
      _dmSignPayload(
        ephemeralPub: ephemeralPubB64,
        nonce: nonceB64,
        ciphertext: ciphertextB64,
      ),
    );
    final valid = await _ed25519.verify(
      signPayload,
      signature: Signature(
        base64Decode(sigRaw),
        publicKey: sender.signPublic,
      ),
    );
    if (!valid) {
      throw const FormatException('Invalid DM signature');
    }
  }

  static Future<Uint8List> _decryptDhAead1Envelope(
    Map<String, dynamic> envelope,
    IdentityKeyPair recipient,
  ) async {
    final ephemeralBytes = base64Decode(envelope['ephemeralPub'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final ephemeralPublic = SimplePublicKey(
      ephemeralBytes,
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipient.agreeKeyPair,
      remotePublicKey: ephemeralPublic,
    );
    final sharedBytes = await shared.extractBytes();
    final aeadKey = await CryptoKdf.hkdf(
      sharedSecret: sharedBytes,
      info: utf8.encode(CryptoConstants.hkdfInfoDhAead),
      salt: ephemeralBytes,
    );
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: ciphertext,
      key: aeadKey,
      nonce: nonce,
    );
  }

  /// Decrypts a signed peer DM (`dm-signed-1`).
  static Future<Uint8List> decryptSignedFromPeer(
    String wire,
    IdentityKeyPair recipient,
    IdentityPublicKeys sender,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null) {
      throw FormatException('Not a v2 crypto envelope');
    }
    if (CryptoEnvelope.schemeOf(envelope) != CryptoConstants.schemeDmSigned1) {
      throw FormatException('Unsupported scheme');
    }
    await _verifyDmSignedEnvelope(envelope, sender);
    return _decryptDhAead1Envelope(envelope, recipient);
  }

  static Future<String> decryptSignedTextFromPeer(
    String wire,
    IdentityKeyPair recipient,
    IdentityPublicKeys sender,
  ) async {
    final bytes = await decryptSignedFromPeer(wire, recipient, sender);
    return utf8.decode(bytes);
  }

  /// Legacy unsigned `dh-aead-1` decrypt (confidentiality only, no sender auth).
  static Future<Uint8List> decryptLegacyFromPeer(
    String wire,
    IdentityKeyPair recipient,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null) {
      throw FormatException('Not a v2 crypto envelope');
    }
    if (CryptoEnvelope.schemeOf(envelope) != CryptoConstants.schemeDhAead1) {
      throw FormatException('Unsupported scheme');
    }
    return _decryptDhAead1Envelope(envelope, recipient);
  }

  static Future<String> decryptLegacyTextFromPeer(
    String wire,
    IdentityKeyPair recipient,
  ) async {
    final bytes = await decryptLegacyFromPeer(wire, recipient);
    return utf8.decode(bytes);
  }

  static Future<Uint8List> decryptFromPeer(
    String wire,
    IdentityKeyPair recipient,
    SimplePublicKey senderAgreePublic,
  ) async {
    return decryptLegacyFromPeer(wire, recipient);
  }

  static Future<String> decryptTextFromPeer(
    String wire,
    IdentityKeyPair recipient,
    SimplePublicKey senderAgreePublic,
  ) async {
    return decryptLegacyTextFromPeer(wire, recipient);
  }

  /// Encrypt for self (uses own agreement public key).
  static Future<String> encryptForSelf(
    Uint8List plaintext,
    IdentityKeyPair identity,
  ) async {
    final pub = await identity.agreePublicKey;
    return encryptForPeer(plaintext, identity, pub);
  }

  static Future<String> encryptTextForSelf(
    String plaintext,
    IdentityKeyPair identity,
  ) =>
      encryptForSelf(utf8.encode(plaintext), identity);

  static Future<Uint8List> decryptForSelf(
    String wire,
    IdentityKeyPair identity,
  ) async {
    return decryptLegacyFromPeer(wire, identity);
  }

  static Future<String> decryptTextForSelf(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final bytes = await decryptForSelf(wire, identity);
    return utf8.decode(bytes);
  }

  /// Wrap a symmetric key for a peer (group key distribution, files).
  static Future<Map<String, dynamic>> wrapKeyForPeer(
    Uint8List keyBytes,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final wire = await encryptForPeer(keyBytes, sender, peerAgreePublic);
    final parsed = CryptoEnvelope.tryParse(wire)!;
    return {
      'ephemeralPub': parsed['ephemeralPub'],
      'nonce': parsed['nonce'],
      'ciphertext': parsed['ciphertext'],
    };
  }

  /// Signed key wrap for authenticated peer file/binary payloads.
  static Future<Map<String, dynamic>> wrapKeyForPeerSigned(
    Uint8List keyBytes,
    IdentityKeyPair sender,
    SimplePublicKey peerAgreePublic,
  ) async {
    final wire = await encryptSignedForPeer(keyBytes, sender, peerAgreePublic);
    final parsed = CryptoEnvelope.tryParse(wire)!;
    return {
      'ephemeralPub': parsed['ephemeralPub'],
      'nonce': parsed['nonce'],
      'ciphertext': parsed['ciphertext'],
      'sig': parsed['sig'],
    };
  }

  static Future<void> _verifySignedWrap(
    Map<String, dynamic> wrapped,
    IdentityPublicKeys sender,
  ) async {
    final sigRaw = wrapped['sig'] as String?;
    if (sigRaw == null) {
      throw const FormatException('Missing signed wrap signature');
    }
    final ephemeralPubB64 = wrapped['ephemeralPub'] as String;
    final nonceB64 = wrapped['nonce'] as String;
    final ciphertextB64 = wrapped['ciphertext'] as String;
    final signPayload = utf8.encode(
      _dmSignPayload(
        ephemeralPub: ephemeralPubB64,
        nonce: nonceB64,
        ciphertext: ciphertextB64,
      ),
    );
    final valid = await _ed25519.verify(
      signPayload,
      signature: Signature(
        base64Decode(sigRaw),
        publicKey: sender.signPublic,
      ),
    );
    if (!valid) {
      throw const FormatException('Invalid signed wrap signature');
    }
  }

  static Future<Uint8List> unwrapKeyFromPeer(
    Map<String, dynamic> wrapped,
    IdentityKeyPair recipient,
  ) async {
    final wire = CryptoEnvelope.encode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDhAead1,
      'alg': 'aes-gcm',
      'ephemeralPub': wrapped['ephemeralPub'],
      'nonce': wrapped['nonce'],
      'ciphertext': wrapped['ciphertext'],
    });
    return decryptLegacyFromPeer(wire, recipient);
  }

  static Future<Uint8List> unwrapSignedKeyFromPeer(
    Map<String, dynamic> wrapped,
    IdentityKeyPair recipient,
    IdentityPublicKeys sender,
  ) async {
    await _verifySignedWrap(wrapped, sender);
    final wire = CryptoEnvelope.encode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': CryptoConstants.schemeDmSigned1,
      'alg': 'aes-gcm',
      'ephemeralPub': wrapped['ephemeralPub'],
      'nonce': wrapped['nonce'],
      'ciphertext': wrapped['ciphertext'],
      'sig': wrapped['sig'],
    });
    return decryptSignedFromPeer(wire, recipient, sender);
  }

  /// File payload: random AEAD key encrypts body; key wrapped for peer/self.
  static Future<({String peerPayload, String selfPayload})> encryptFile(
    Uint8List bytes,
    IdentityKeyPair identity,
    SimplePublicKey peerAgreePublic,
  ) async {
    final fileKey = CryptoKdf.randomBytes(CryptoConstants.aeadKeyLength);
    final aeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    final enc = await CryptoAead.encryptAesGcm(bytes, key: aeadKey);
    final selfPub = await identity.agreePublicKey;
    final peerWrapped =
        await wrapKeyForPeerSigned(fileKey, identity, peerAgreePublic);
    final selfWrapped = await wrapKeyForPeer(fileKey, identity, selfPub);
    final peerPayload = CryptoEnvelope.encode(CryptoEnvelope.fileSigned1(
      wrappedKey: peerWrapped,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
    final selfPayload = CryptoEnvelope.encode(CryptoEnvelope.fileAead1(
      wrappedKey: selfWrapped,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    ));
    return (peerPayload: peerPayload, selfPayload: selfPayload);
  }

  static Future<Uint8List> _decryptFileEnvelope(
    Map<String, dynamic> envelope,
    IdentityKeyPair recipient, {
    IdentityPublicKeys? sender,
    bool allowLegacyUnsignedFile = false,
  }) async {
    final scheme = CryptoEnvelope.schemeOf(envelope);
    final wrapped = envelope['wrappedKey'] as Map<String, dynamic>;
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final Uint8List fileKey;
    if (scheme == CryptoConstants.schemeFileSigned1) {
      if (sender == null) {
        throw const FormatException('Missing sender keys for signed file');
      }
      fileKey = await unwrapSignedKeyFromPeer(wrapped, recipient, sender);
    } else if (scheme == CryptoConstants.schemeFileAead1) {
      if (!allowLegacyUnsignedFile) {
        throw const FormatException('Unsigned peer file rejected');
      }
      fileKey = await unwrapKeyFromPeer(wrapped, recipient);
    } else {
      throw FormatException('Invalid file envelope scheme: $scheme');
    }
    final aeadKey = await CryptoAead.secretKeyFromBytes(fileKey);
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: ciphertext,
      key: aeadKey,
      nonce: nonce,
    );
  }

  static Future<Uint8List> decryptFile(
    String wire,
    IdentityKeyPair identity,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null || envelope['scheme'] != CryptoConstants.schemeFileAead1) {
      throw FormatException('Invalid file envelope');
    }
    return _decryptFileEnvelope(
      envelope,
      identity,
      allowLegacyUnsignedFile: true,
    );
  }

  /// Decrypts a peer-sent file (`file-signed-1` or legacy `file-aead-1`).
  static Future<Uint8List> decryptFileFromPeer(
    String wire,
    IdentityKeyPair recipient,
    IdentityPublicKeys sender, {
    bool allowLegacyUnsignedFile = false,
  }) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null) {
      throw FormatException('Invalid file envelope');
    }
    final scheme = CryptoEnvelope.schemeOf(envelope);
    if (scheme != CryptoConstants.schemeFileSigned1 &&
        scheme != CryptoConstants.schemeFileAead1) {
      throw FormatException('Invalid peer file envelope scheme: $scheme');
    }
    return _decryptFileEnvelope(
      envelope,
      recipient,
      sender: sender,
      allowLegacyUnsignedFile: allowLegacyUnsignedFile,
    );
  }

  /// Verifies signed wrap signature without decrypting the file body.
  static Future<void> verifySignedFileWrap(
    String wire,
    IdentityPublicKeys sender,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeFileSigned1) {
      throw const FormatException('Not a signed file envelope');
    }
    final wrapped = envelope['wrappedKey'] as Map<String, dynamic>;
    await _verifySignedWrap(wrapped, sender);
  }

  /// Verifies dm-signed-1 signature without decrypting plaintext.
  static Future<void> verifyDmSignedWire(
    String wire,
    IdentityPublicKeys sender,
  ) async {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeDmSigned1) {
      throw const FormatException('Not a dm-signed envelope');
    }
    await _verifyDmSignedEnvelope(envelope, sender);
  }
}
