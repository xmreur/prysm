import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/crypto/aead.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/kdf.dart';

/// Simplified Double Ratchet session for 1:1 chats (Phase 2).
///
/// Two session versions coexist:
///  * v2 (legacy): message keys are derived statically from the root
///    [sharedMaterial], which is persisted in the session JSON. Kept
///    verbatim so existing chats survive an upgrade.
///  * v3 (hash-chain): message keys come from a one-way ratchet over
///    per-direction chain keys. Each step consumes the chain key (the old
///    value is dropped) and only the *current* chain keys are persisted —
///    past message keys are unrecoverable from a stolen session row.
class RatchetSession {
  /// Legacy session derived statically from [sharedMaterial].
  RatchetSession.v2({
    required this.sharedMaterial,
    required this.isInitiator,
    required this.sendCounter,
    required this.recvCounter,
    Set<int>? skippedCounters,
    this.peerWireScheme,
  }) : version = 2,
       sendChainKey = null,
       recvChainKey = null,
       recvSkippedKeys = const <int, String>{},
       skippedCounters = skippedCounters ?? <int>{};

  /// Forward-secret session backed by one-way chain keys.
  RatchetSession.v3({
    required this.isInitiator,
    required this.sendChainKey,
    required this.recvChainKey,
    required this.sendCounter,
    required this.recvCounter,
    Map<int, String>? recvSkippedKeys,
    String? peerWireScheme,
  }) : version = 3,
       sharedMaterial = null,
       recvSkippedKeys = recvSkippedKeys ?? <int, String>{},
       skippedCounters = const <int>{},
       peerWireScheme =
           peerWireScheme ?? CryptoConstants.schemeRatchet3;

  /// 2 for legacy sessions, 3 for hash-chain sessions.
  final int version;

  /// Static root material — v2 only; null on v3 sessions (never persisted).
  final Uint8List? sharedMaterial;

  /// Current outbound chain key — v3 only. Consumed on every send.
  Uint8List? sendChainKey;

  /// Current inbound chain key — v3 only. Consumed on every receive.
  Uint8List? recvChainKey;

  /// Message keys stashed for skipped (late) inbound counters, keyed by
  /// counter — v3 only. Values are base64-encoded 32-byte keys. A skipped
  /// key is deleted once used.
  final Map<int, String> recvSkippedKeys;

  final bool isInitiator;
  int sendCounter;
  int recvCounter;

  /// Skipped counters — v2 only.
  final Set<int> skippedCounters;

  /// Highest ratchet wire scheme known for the remote peer (learned from
  /// profile or inbound messages). Governs outbound scheme selection.
  String? peerWireScheme;

  static final Uint8List _ratchetSalt = Uint8List.fromList(
    utf8.encode('prysm/ratchet/root-salt'),
  );

  /// Two distinct chain-seed infos so initiator and responder derive
  /// mirrored chains: init.send == resp.recv (info a) and
  /// init.recv == resp.send (info b).
  static final Uint8List _chainSeedInfoA = Uint8List.fromList(
    utf8.encode('prysm/ratchet/chain/a'),
  );
  static final Uint8List _chainSeedInfoB = Uint8List.fromList(
    utf8.encode('prysm/ratchet/chain/b'),
  );
  static final Uint8List _chainMsgInfo = Uint8List.fromList(
    utf8.encode('prysm/ratchet/chain/msg'),
  );
  static final Uint8List _chainNextInfo = Uint8List.fromList(
    utf8.encode('prysm/ratchet/chain/next'),
  );

  /// Legacy v2 session (static HKDF from [sharedMaterial]). Retained for
  /// sessions already persisted in the DB.
  static Future<RatchetSession> initializeAsInitiator(
    Uint8List sharedMaterial, {
    String? peerWireScheme,
  }) async {
    return RatchetSession.v2(
      sharedMaterial: sharedMaterial,
      isInitiator: true,
      sendCounter: 0,
      recvCounter: -1,
      peerWireScheme: peerWireScheme,
    );
  }

  static Future<RatchetSession> initializeAsResponder(
    Uint8List sharedMaterial, {
    String? peerWireScheme,
  }) async {
    return RatchetSession.v2(
      sharedMaterial: sharedMaterial,
      isInitiator: false,
      sendCounter: 0,
      recvCounter: -1,
      peerWireScheme: peerWireScheme,
    );
  }

  /// Forward-secret v3 session. Derives the two chain seeds from
  /// [sharedMaterial] and does not retain it; the caller should drop its
  /// own reference too.
  static Future<RatchetSession> initializeV3AsInitiator(
    Uint8List sharedMaterial, {
    String? peerWireScheme,
  }) async {
    final send = await _chainSeed(sharedMaterial, _chainSeedInfoA);
    final recv = await _chainSeed(sharedMaterial, _chainSeedInfoB);
    return RatchetSession.v3(
      isInitiator: true,
      sendChainKey: send,
      recvChainKey: recv,
      sendCounter: 0,
      recvCounter: -1,
      peerWireScheme: peerWireScheme,
    );
  }

  static Future<RatchetSession> initializeV3AsResponder(
    Uint8List sharedMaterial, {
    String? peerWireScheme,
  }) async {
    final send = await _chainSeed(sharedMaterial, _chainSeedInfoB);
    final recv = await _chainSeed(sharedMaterial, _chainSeedInfoA);
    return RatchetSession.v3(
      isInitiator: false,
      sendChainKey: send,
      recvChainKey: recv,
      sendCounter: 0,
      recvCounter: -1,
      peerWireScheme: peerWireScheme,
    );
  }

  String _emitWireScheme() {
    if (version == 3) {
      if (!CryptoConstants.peerSupportsRatchet3(peerWireScheme)) {
        throw StateError('v3 session requires peer ratchet-3 capability');
      }
      return CryptoConstants.schemeRatchet3;
    }
    return peerWireScheme == CryptoConstants.schemeRatchet2
        ? CryptoConstants.schemeRatchet2
        : CryptoConstants.schemeRatchet1;
  }

  void _notePeerWireScheme(String scheme) {
    peerWireScheme = CryptoConstants.maxRatchetScheme(peerWireScheme, scheme);
  }

  Future<({String wire, Map<String, dynamic> handshake})> encryptMessage(
    Uint8List plaintext, {
    Map<String, dynamic>? handshake,
  }) async {
    final counter = sendCounter;
    final List<int> messageKey;
    if (version == 3) {
      messageKey = await _nextSendMessageKey();
    } else {
      messageKey = await _messageKey(
        role: isInitiator ? 'send' : 'recv',
        counter: counter,
      );
    }
    sendCounter++;
    final scheme = _emitWireScheme();
    const alg = 'aes-gcm';
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final associatedData = scheme == CryptoConstants.schemeRatchet1
        ? const <int>[]
        : CryptoEnvelope.ratchetAad(
            scheme: scheme,
            counter: counter,
            alg: alg,
            handshake: handshake,
          );
    final enc = await CryptoAead.encryptAesGcm(
      plaintext,
      key: aeadKey,
      associatedData: associatedData,
    );
    final wire = jsonEncode({
      'crypto': CryptoConstants.cryptoVersion,
      'scheme': scheme,
      'alg': alg,
      'nonce': base64Encode(enc.nonce),
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': counter,
    });
    return (wire: wire, handshake: handshake ?? <String, dynamic>{});
  }

  Future<Uint8List> decryptMessage(String wire) async {
    final envelope = jsonDecode(wire) as Map<String, dynamic>;
    final scheme = envelope['scheme'] as String?;
    if (scheme != CryptoConstants.schemeRatchet1 &&
        scheme != CryptoConstants.schemeRatchet2 &&
        scheme != CryptoConstants.schemeRatchet3) {
      throw FormatException('Not a ratchet message');
    }
    if (version == 3) {
      return _decryptV3(envelope, scheme!);
    }
    return _decryptV2(envelope, scheme!);
  }

  /// v3 inbound path: chain-ratchet (forward-secret) with skipped-key stash.
  Future<Uint8List> _decryptV3(
    Map<String, dynamic> envelope,
    String scheme,
  ) async {
    // v3 sessions only ever speak to other v3 sessions.
    if (scheme != CryptoConstants.schemeRatchet3) {
      throw FormatException('Not a ratchet message');
    }
    final counter = envelope['counter'] as int;
    // Consuming the chain (and stashing skipped keys) happens before the
    // AEAD check: a hash chain cannot rewind, so a failed attempt still
    // ratchets. Skipped keys survive (they are stashed, not consumed).
    final messageKey = await _recvMessageKeyV3(counter);
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    return CryptoAead.decryptAesGcm(
      ciphertextWithTag: base64Decode(envelope['ciphertext'] as String),
      key: aeadKey,
      nonce: base64Decode(envelope['nonce'] as String),
      associatedData: CryptoEnvelope.ratchetAad(
        scheme: scheme,
        counter: counter,
        alg: envelope['alg'] as String? ?? 'aes-gcm',
        crypto: envelope['crypto'] as String? ?? CryptoConstants.cryptoVersion,
        handshake: envelope['handshake'] as Map<String, dynamic>?,
      ),
    ).then((plain) {
      _notePeerWireScheme(scheme);
      return plain;
    });
  }

  /// Legacy v2 inbound path — exact prior behavior.
  Future<Uint8List> _decryptV2(
    Map<String, dynamic> envelope,
    String scheme,
  ) async {
    final counter = envelope['counter'] as int;
    final isLateSkipped = skippedCounters.contains(counter);
    if (counter <= recvCounter && !isLateSkipped) {
      throw StateError('Replay detected');
    }
    if (!isLateSkipped && counter > recvCounter + 1) {
      final gap = counter - (recvCounter + 1);
      if (gap > CryptoConstants.ratchetMaxSkip) {
        throw StateError('Counter too far ahead');
      }
    }
    final messageKey = await _messageKey(
      role: isInitiator ? 'recv' : 'send',
      counter: counter,
    );
    final aeadKey = await CryptoAead.secretKeyFromBytes(
      Uint8List.fromList(messageKey),
    );
    final associatedData = scheme == CryptoConstants.schemeRatchet2
        ? CryptoEnvelope.ratchetAad(
            scheme: scheme,
            counter: counter,
            alg: envelope['alg'] as String? ?? 'aes-gcm',
            crypto:
                envelope['crypto'] as String? ?? CryptoConstants.cryptoVersion,
            handshake: envelope['handshake'] as Map<String, dynamic>?,
          )
        : const <int>[];
    final plain = await CryptoAead.decryptAesGcm(
      ciphertextWithTag: base64Decode(envelope['ciphertext'] as String),
      key: aeadKey,
      nonce: base64Decode(envelope['nonce'] as String),
      associatedData: associatedData,
    );
    if (isLateSkipped) {
      skippedCounters.remove(counter);
    } else if (counter > recvCounter + 1) {
      for (var i = recvCounter + 1; i < counter; i++) {
        skippedCounters.add(i);
      }
      recvCounter = counter;
    } else {
      recvCounter = counter;
    }
    _notePeerWireScheme(scheme);
    return plain;
  }

  /// Resolves the inbound message key for [counter] under the v3 chain:
  ///  * counter already stashed in [recvSkippedKeys] → return it and delete
  ///    the stash entry (one-time use);
  ///  * next in sequence → ratchet the chain one step;
  ///  * gap ≤ `ratchetMaxSkip` → ratchet step by step, stashing the keys of
  ///    every intermediate counter before advancing past it;
  ///  * anything else → replay.
  Future<List<int>> _recvMessageKeyV3(int counter) async {
    final skippedKey = recvSkippedKeys.remove(counter);
    if (skippedKey != null) {
      return base64Decode(skippedKey);
    }
    if (counter <= recvCounter) {
      throw StateError('Replay detected');
    }
    final gap = counter - (recvCounter + 1);
    if (gap > CryptoConstants.ratchetMaxSkip) {
      throw StateError('Counter too far ahead');
    }
    final steps = gap + 1;
    var chain = recvChainKey!;
    Uint8List? targetKey;
    for (var i = 0; i < steps; i++) {
      final msgKey = await _deriveMessageKeyFromChain(chain);
      final current = recvCounter + 1 + i;
      if (current == counter) {
        targetKey = msgKey;
      } else {
        // The chain is about to ratchet past `current`: stash its message
        // key now or the late message becomes undecryptable.
        recvSkippedKeys[current] = base64Encode(msgKey);
      }
      chain = await _nextChainKey(chain);
    }
    recvChainKey = chain;
    recvCounter = counter;
    return targetKey!;
  }

  /// Ratchets the outbound chain one step and returns the message key for
  /// the current position; the previous chain key is dropped.
  Future<List<int>> _nextSendMessageKey() async {
    final chain = sendChainKey!;
    final messageKey = await _deriveMessageKeyFromChain(chain);
    sendChainKey = await _nextChainKey(chain);
    return messageKey;
  }

  Future<List<int>> _messageKey({
    required String role,
    required int counter,
  }) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: sharedMaterial!,
      info: utf8.encode(
        '${CryptoConstants.hkdfInfoRatchet}/$role/msg/$counter',
      ),
      salt: _ratchetSalt,
    );
    return await key.extractBytes();
  }

  static Future<Uint8List> _chainSeed(
    Uint8List sharedMaterial,
    Uint8List info,
  ) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: sharedMaterial,
      info: info,
      salt: _ratchetSalt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> _deriveMessageKeyFromChain(
    Uint8List chainKey,
  ) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: chainKey,
      info: _chainMsgInfo,
      salt: _ratchetSalt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> _nextChainKey(Uint8List chainKey) async {
    final key = await CryptoKdf.hkdf(
      sharedSecret: chainKey,
      info: _chainNextInfo,
      salt: _ratchetSalt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  Map<String, dynamic> toJson() {
    if (version == 3) {
      // Forward secrecy: persist only the current chain keys and the stashed
      // skipped message keys — never the root material.
      return {
        'version': 3,
        'isInitiator': isInitiator,
        'sendChainKey': base64Encode(sendChainKey!),
        'recvChainKey': base64Encode(recvChainKey!),
        'recvSkippedKeys': {
          for (final entry in recvSkippedKeys.entries)
            '${entry.key}': entry.value,
        },
        'sendCounter': sendCounter,
        'recvCounter': recvCounter,
        if (peerWireScheme != null) 'peerWireScheme': peerWireScheme,
      };
    }
    return {
      'sharedMaterial': base64Encode(sharedMaterial!),
      'isInitiator': isInitiator,
      'sendCounter': sendCounter,
      'recvCounter': recvCounter,
      'skippedCounters': (skippedCounters.toList()..sort()),
      if (peerWireScheme != null) 'peerWireScheme': peerWireScheme,
    };
  }

  static RatchetSession fromJson(Map<String, dynamic> json) {
    // Rows persisted before v3 have no 'version' key — treat them as v2.
    final version = json['version'] as int? ?? 2;
    if (version == 3) {
      return RatchetSession.v3(
        isInitiator: json['isInitiator'] as bool? ?? true,
        sendChainKey: base64Decode(json['sendChainKey'] as String),
        recvChainKey: base64Decode(json['recvChainKey'] as String),
        recvSkippedKeys: {
          for (final entry
              in (json['recvSkippedKeys'] as Map<String, dynamic>? ??
                      const <String, dynamic>{})
                  .entries)
            int.parse(entry.key): entry.value as String,
        },
        sendCounter: json['sendCounter'] as int,
        recvCounter: json['recvCounter'] as int,
        peerWireScheme: CryptoConstants.parseRatchetScheme(
          json['peerWireScheme'] as String?,
        ) ??
            CryptoConstants.schemeRatchet3,
      );
    }
    return RatchetSession.v2(
      sharedMaterial: base64Decode(json['sharedMaterial'] as String),
      isInitiator: json['isInitiator'] as bool? ?? true,
      sendCounter: json['sendCounter'] as int,
      recvCounter: json['recvCounter'] as int,
      skippedCounters: Set<int>.from(
        (json['skippedCounters'] as List<dynamic>?) ?? const [],
      ),
      peerWireScheme: CryptoConstants.parseRatchetScheme(
        json['peerWireScheme'] as String?,
      ),
    );
  }
}
