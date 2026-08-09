import 'dart:async';
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
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';

/// High-level 1:1 ratchet encrypt/decrypt with SQLite session persistence.
class RatchetService {
  RatchetService._({RatchetSessionStore? sessionStore})
    : _sessionStore = sessionStore;

  static final RatchetService instance = RatchetService._();

  RatchetSessionStore? _sessionStore;
  final Map<String, Mutex> _peerLocks = {};

  /// The one in-flight profile fetch per peer. Both the foreground
  /// resolve path and the background warm share this future, so a peer
  /// whose profile never answers cannot pile up one fetch per message
  /// (or per cold bootstrap). The entry is removed when the fetch
  /// settles; while it hangs, every cold caller waits on the same
  /// request instead of starting a new one.
  final Map<String, Future<String?>> _inFlightSchemeFetches = {};

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

  /// Bounds the scheme profile fetch: a single attempt, a short timeout and
  /// no TorDelivery retry/NEWNYM (maxAttempts 1 never reaches the
  /// circuit-refresh branch of withTorRetry), so a cold first send cannot
  /// pay 3 x 20s or tear down healthy circuits.
  static const Duration _schemeFetchTimeout = Duration(seconds: 3);

  Future<String?> _peerRatchetSchemeFromProfile(String peerId) async {
    final fetcher = _peerRatchetSchemeFetcher;
    if (fetcher != null) {
      return CryptoConstants.parseRatchetScheme(await fetcher(peerId));
    }
    try {
      final body = await TransportProvider.getProfileOrFallback(
        peerId,
        timeout: _schemeFetchTimeout,
        maxAttempts: 1,
        preference: TransportPreference.httpOnly,
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      return CryptoConstants.parseRatchetScheme(data['ratchetScheme']);
    } catch (_) {
      return null;
    }
  }

  /// The peer ratchet scheme persisted on the `users` row, warmed by the
  /// profile fetches the app already performs (ContactAddService,
  /// PeerIdentityResolver, the chat screen refresh and the inbound
  /// sender-profile refresh). Null when unknown.
  Future<String?> _cachedPeerRatchetScheme(String peerId) async {
    try {
      final user = await DBHelper.getUserById(peerId);
      return CryptoConstants.parseRatchetScheme(user?['ratchetScheme']);
    } catch (_) {
      return null;
    }
  }

  /// Persists [scheme] for [peerId]. A missing `users` row (or a
  /// pre-migration schema without the column) leaves the cache cold and is
  /// not an error: the next cold bootstrap simply re-warms.
  Future<void> _persistPeerRatchetScheme(String peerId, String scheme) async {
    try {
      await DBHelper.updateUserFields(peerId, {'ratchetScheme': scheme});
    } catch (_) {
      // Deliberately silent: a cold cache only costs another bounded
      // background fetch.
    }
  }

  /// Returns the one shared in-flight profile fetch for [peerId], starting
  /// it if none is running. Never throws: fetch and persistence failures
  /// surface as a null scheme. The scheme is persisted off this shared
  /// future, so the result is stored even when the foreground caller has
  /// already timed out and moved on. The entry is cleared when the future
  /// settles, letting the next cold bootstrap start a fresh fetch.
  Future<String?> _sharedSchemeFetch(String peerId) {
    final inFlight = _inFlightSchemeFetches[peerId];
    if (inFlight != null) return inFlight;
    final future = _peerRatchetSchemeFromProfile(peerId).then((scheme) async {
      if (scheme == null) return null;
      await _persistPeerRatchetScheme(peerId, scheme);
      return scheme;
    });
    _inFlightSchemeFetches[peerId] = future;
    unawaited(future.whenComplete(() {
      // Only clear our own entry: a newer fetch for the same peer must not
      // be evicted by the settling of this one.
      if (identical(_inFlightSchemeFetches[peerId], future)) {
        _inFlightSchemeFetches.remove(peerId);
      }
    }));
    return future;
  }

  /// Bounded background scheme refresh for a cold cache. Never throws.
  /// A second warm for the same peer while a fetch is in flight reuses
  /// the shared fetch instead of starting a new one.
  Future<void> _warmPeerRatchetScheme(String peerId) async {
    unawaited(_sharedSchemeFetch(peerId));
  }

  /// Resolves the peer's ratchet scheme for a NEW session. The persisted
  /// cache is consulted first; only a cold cache awaits the already-bounded
  /// profile fetch (single attempt, ~3s, no NEWNYM), so a reachable peer
  /// negotiates v3 instead of silently downgrading to the v2 initializer.
  /// On fetch failure or timeout the send falls back to v2 and re-warms in
  /// the background, keeping the first send bounded (never the old 3 x 20s
  /// + NEWNYM behaviour).
  Future<String?> _resolvePeerRatchetScheme(
    String peerId,
    RatchetSession? session,
  ) async {
    final cached =
        session?.peerWireScheme ?? await _cachedPeerRatchetScheme(peerId);
    if (cached != null) {
      return cached;
    }
    String? fromProfile;
    try {
      // The bound is enforced here, not only passed to the fetch: the device
      // log is full of Tor futures that never complete ("TimeoutException
      // after 0:00:30: Future not completed"), and a send must stay bounded
      // even if the transport fails to honour its own timeout. The timeout
      // stops THIS caller waiting; the shared fetch keeps running so a
      // background warm (or the next cold bootstrap) reuses it instead of
      // starting a duplicate fetch.
      fromProfile = await _sharedSchemeFetch(
        peerId,
      ).timeout(_schemeFetchTimeout);
    } catch (_) {
      // Fetch failed or timed out: fall through to the v2 fallback below.
    }
    if (fromProfile != null) {
      // Persistence hangs off the shared fetch (see _sharedSchemeFetch), so
      // the cache is already warm by the time the future completed here.
      return fromProfile;
    }
    unawaited(_warmPeerRatchetScheme(peerId));
    return null;
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
