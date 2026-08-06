import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/transport/transport_provider.dart';

/// High-level 1:1 ratchet encrypt/decrypt with SQLite session persistence.
class RatchetService {
  RatchetService._({RatchetSessionStore? sessionStore})
    : _sessionStore = sessionStore;

  static final RatchetService instance = RatchetService._();

  RatchetSessionStore? _sessionStore;
  final Map<String, Mutex> _peerLocks = {};

  /// Test override for peer profile ratchet-scheme lookup.
  Future<String?> Function(String peerId)? _peerRatchetSchemeFetcher;

  @visibleForTesting
  void setPeerRatchetSchemeFetcherForTest(
    Future<String?> Function(String peerId)? fetcher,
  ) {
    _peerRatchetSchemeFetcher = fetcher;
  }

  Mutex _lockFor(String peerId) => _peerLocks.putIfAbsent(peerId, Mutex.new);

  /// Injects the [RatchetSessionStore] used for persistence.
  /// The wiring is performed by the application database helper.
  void setSessionStore(RatchetSessionStore store) {
    _sessionStore = store;
  }

  RatchetSessionStore get _store {
    final store = _sessionStore;
    if (store == null) {
      throw StateError('RatchetService session store not initialized');
    }
    return store;
  }

  static final X25519 _x25519 = X25519();

  Future<String?> _peerRatchetSchemeFromProfile(String peerId) async {
    final fetcher = _peerRatchetSchemeFetcher;
    if (fetcher != null) {
      return CryptoConstants.parseRatchetScheme(await fetcher(peerId));
    }
    try {
      final body = await TransportProvider.getProfileOrFallback(peerId);
      final data = jsonDecode(body) as Map<String, dynamic>;
      return CryptoConstants.parseRatchetScheme(
        data['ratchetScheme'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolvePeerRatchetScheme(
    String peerId,
    RatchetSession? session,
  ) async {
    final cached = session?.peerWireScheme;
    final profile = await _peerRatchetSchemeFromProfile(peerId);
    return CryptoConstants.maxRatchetScheme(cached, profile);
  }

  Future<String> encryptText({
    required String peerId,
    required String plaintext,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    PrekeyBundle? peerBundle,
  }) async {
    final wire = await encryptBytes(
      peerId: peerId,
      plaintext: utf8.encode(plaintext),
      local: local,
      peer: peer,
      peerBundle: peerBundle,
    );
    return wire;
  }

  Future<String> encryptBytes({
    required String peerId,
    required Uint8List plaintext,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    PrekeyBundle? peerBundle,
  }) => _lockFor(peerId).protect(() async {
    var session = await _store.load(peerId);
    Map<String, dynamic> handshake = {};

    if (session == null) {
      final bundle = peerBundle;
      if (bundle == null) {
        throw StateError('Missing prekey bundle for $peerId');
      }
      final ephemeral = await _x25519.newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final shared = await PrekeyBundle.sharedSecretAsInitiator(
        local: local,
        peer: peer,
        peerBundle: bundle,
        ephemeral: ephemeral,
      );
      final peerScheme = await _resolvePeerRatchetScheme(peerId, null);
      session = CryptoConstants.peerSupportsRatchet3(peerScheme)
          ? await RatchetSession.initializeV3AsInitiator(
              shared,
              peerWireScheme: peerScheme,
            )
          : await RatchetSession.initializeAsInitiator(
              shared,
              peerWireScheme: peerScheme,
            );
      final oneTime = bundle.oneTimePreKeyPublic;
      handshake = {
        'ephemeralPub': base64Encode(ephemeralPublic.bytes),
        if (oneTime != null) 'oneTimePreKey': base64Encode(oneTime.bytes),
      };
    }

    final result = await session.encryptMessage(
      plaintext,
      handshake: handshake.isEmpty ? null : handshake,
    );
    await _store.save(peerId, session);
    if (handshake.isEmpty) {
      return result.wire;
    }
    final envelope = jsonDecode(result.wire) as Map<String, dynamic>;
    envelope['handshake'] = handshake;
    return jsonEncode(envelope);
  });

  Future<String> decryptText({
    required String peerId,
    required String wire,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    bool allowLegacyUnsignedDhAead = false,
  }) => decryptBytes(
    peerId: peerId,
    wire: wire,
    local: local,
    peer: peer,
    allowLegacyUnsignedDhAead: allowLegacyUnsignedDhAead,
  ).then(utf8.decode);

  Future<Uint8List> decryptBytes({
    required String peerId,
    required String wire,
    required IdentityKeyPair local,
    required IdentityPublicKeys peer,
    bool allowLegacyUnsignedDhAead = false,
  }) async {
    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    final scheme = envelope['scheme'] as String?;

    if (scheme == CryptoConstants.schemeDmSigned1 ||
        scheme == CryptoConstants.schemeDmSigned2) {
      return CryptoWire.decryptSignedFromPeer(wire, local, peer);
    }

    if (scheme == CryptoConstants.schemeDhAead1 ||
        scheme == CryptoConstants.schemeDhAead2) {
      if (!allowLegacyUnsignedDhAead) {
        throw const FormatException('Unsigned peer message rejected');
      }
      return CryptoWire.decryptLegacyFromPeer(wire, local);
    }

    if (scheme != CryptoConstants.schemeRatchet1 &&
        scheme != CryptoConstants.schemeRatchet2 &&
        scheme != CryptoConstants.schemeRatchet3) {
      // A peer running an older build rejects ratchet-3 here with this clean
      // error; that is expected and safe (v3 is only spoken between updated
      // peers that both bootstrap fresh v3 sessions).
      throw FormatException('Unsupported ciphertext scheme: $scheme');
    }

    return _lockFor(peerId).protect(() async {
      SimplePublicKey? consumedOneTime;
      try {
        var session = await _store.load(peerId);
        if (session == null) {
          final handshake = envelope['handshake'] as Map<String, dynamic>?;
          if (handshake == null) {
            throw StateError('Missing ratchet handshake for $peerId');
          }
          final ephemeralBytes = base64Decode(
            handshake['ephemeralPub'] as String,
          );
          final ephemeralPublic = SimplePublicKey(
            ephemeralBytes,
            type: KeyPairType.x25519,
          );
          SimplePublicKey? usedOneTime;
          final oneTimeRaw = handshake['oneTimePreKey'] as String?;
          if (oneTimeRaw != null) {
            usedOneTime = SimplePublicKey(
              base64Decode(oneTimeRaw),
              type: KeyPairType.x25519,
            );
          }
          final shared = await PrekeyBundle.sharedSecretAsResponder(
            local: local,
            peer: peer,
            initiatorEphemeralPublic: ephemeralPublic,
            usedOneTimePreKeyPublic: usedOneTime,
          );
          if (shared == null) {
            throw StateError('Cannot derive ratchet session for $peerId');
          }
          consumedOneTime = shared.usedOneTimePreKeyPublic;
          final inboundScheme = CryptoConstants.parseRatchetScheme(scheme);
          session = scheme == CryptoConstants.schemeRatchet3
              ? await RatchetSession.initializeV3AsResponder(
                  shared.material,
                  peerWireScheme: inboundScheme,
                )
              : await RatchetSession.initializeAsResponder(
                  shared.material,
                  peerWireScheme: inboundScheme,
                );
        }

        final plain = await session.decryptMessage(wire);
        await _store.save(peerId, session);
        final consumed = consumedOneTime;
        if (consumed != null) {
          await PrekeyBundle.commitOneTimePreKeyConsumption(consumed);
          consumedOneTime = null; // committed: nothing left to release.
        }
        return plain;
      } finally {
        // A handshake that was looked up but never committed must release its
        // in-use mark, otherwise the one-time prekey would stay unresolvable.
        final inUse = consumedOneTime;
        if (inUse != null) {
          await PrekeyBundle.releaseOneTimePreKey(inUse);
        }
      }
    });
  }
}
