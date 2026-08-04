import 'dart:convert';

import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/ratchet_service.dart';
import 'package:prysm/crypto/wire.dart';
import 'package:prysm/util/key_manager.dart';

/// Result of inbound direct-message authentication.
enum DirectAuthOutcome {
  accepted,
  pendingAuth,
  rejected,
}

const Set<String> _directMediaTypes = {'file', 'image', 'audio'};

/// Authenticates inbound 1:1 ciphertext before storage or promotion.
class DirectMessageAuth {
  DirectMessageAuth._();

  static String? _schemeOfWire(String wire) {
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null) {
      final parsed = _tryParseRatchetWire(wire);
      return parsed?['scheme'] as String?;
    }
    return CryptoEnvelope.schemeOf(envelope);
  }

  static Map<String, dynamic>? _tryParseRatchetWire(String wire) {
    final trimmed = wire.trimLeft();
    if (!trimmed.startsWith('{')) return null;
    try {
      final parsed = jsonDecode(wire);
      if (parsed is! Map<String, dynamic>) return null;
      if (parsed['crypto'] != CryptoConstants.cryptoVersion) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  static bool _isDirectMediaType(String type) => _directMediaTypes.contains(type);

  static Future<DirectAuthOutcome> authenticateInboundDirect({
    required String senderId,
    required String wire,
    required String type,
    required String? localUserId,
    required KeyManager keyManager,
    required Future<IdentityPublicKeys?> Function(String peerId) resolveIdentity,
    bool fullDecrypt = true,
    bool allowLegacyUnsignedDhAead = false,
    bool allowLegacyUnsignedFile = false,
  }) async {
    if (localUserId != null && senderId == localUserId) {
      return DirectAuthOutcome.accepted;
    }

    if (!isDirectMessageType(type)) {
      return DirectAuthOutcome.accepted;
    }

    final scheme = _schemeOfWire(wire);
    if (scheme == null) {
      return fullDecrypt
          ? DirectAuthOutcome.rejected
          : DirectAuthOutcome.pendingAuth;
    }

    final peerKeys = await resolveIdentity(senderId);

    if (scheme == CryptoConstants.schemeDmSigned1 ||
        scheme == CryptoConstants.schemeDmSigned2) {
      if (peerKeys == null) {
        return fullDecrypt
            ? DirectAuthOutcome.rejected
            : DirectAuthOutcome.pendingAuth;
      }
      try {
        if (fullDecrypt && keyManager.isUnlocked) {
          await keyManager.decryptPeerMessage(
            peerId: senderId,
            wire: wire,
            peer: peerKeys,
            allowLegacyUnsignedDhAead: false,
          );
        } else {
          await CryptoWire.verifyDmSignedWire(wire, peerKeys);
        }
        return fullDecrypt && keyManager.isUnlocked
            ? DirectAuthOutcome.accepted
            : DirectAuthOutcome.pendingAuth;
      } catch (_) {
        return DirectAuthOutcome.rejected;
      }
    }

    if (_isDirectMediaType(type) &&
        scheme == CryptoConstants.schemeFileSigned1) {
      if (peerKeys == null) {
        return fullDecrypt
            ? DirectAuthOutcome.rejected
            : DirectAuthOutcome.pendingAuth;
      }
      try {
        if (fullDecrypt && keyManager.isUnlocked) {
          await CryptoWire.decryptFileFromPeer(
            wire,
            keyManager.identity,
            peerKeys,
            allowLegacyUnsignedFile: false,
          );
        } else {
          await CryptoWire.verifySignedFileWrap(wire, peerKeys);
        }
        return fullDecrypt && keyManager.isUnlocked
            ? DirectAuthOutcome.accepted
            : DirectAuthOutcome.pendingAuth;
      } catch (_) {
        return DirectAuthOutcome.rejected;
      }
    }

    if (scheme == CryptoConstants.schemeRatchet1 ||
        scheme == CryptoConstants.schemeRatchet2) {
      if (!fullDecrypt || !keyManager.isUnlocked || peerKeys == null) {
        return DirectAuthOutcome.pendingAuth;
      }
      try {
        await RatchetService.instance.decryptText(
          peerId: senderId,
          wire: wire,
          local: keyManager.identity,
          peer: peerKeys,
          allowLegacyUnsignedDhAead: false,
        );
        return DirectAuthOutcome.accepted;
      } catch (_) {
        return DirectAuthOutcome.rejected;
      }
    }

    if (scheme == CryptoConstants.schemeDhAead1 ||
        scheme == CryptoConstants.schemeDhAead2) {
      if (peerKeys == null) {
        return fullDecrypt
            ? DirectAuthOutcome.rejected
            : DirectAuthOutcome.pendingAuth;
      }
      if (!allowLegacyUnsignedDhAead) {
        return DirectAuthOutcome.rejected;
      }
      if (!fullDecrypt || !keyManager.isUnlocked) {
        return DirectAuthOutcome.pendingAuth;
      }
      try {
        await keyManager.decryptPeerMessage(
          peerId: senderId,
          wire: wire,
          peer: peerKeys,
          allowLegacyUnsignedDhAead: true,
        );
        return DirectAuthOutcome.accepted;
      } catch (_) {
        return DirectAuthOutcome.rejected;
      }
    }

    if (_isDirectMediaType(type) &&
        scheme == CryptoConstants.schemeFileAead1) {
      if (peerKeys == null) {
        return fullDecrypt
            ? DirectAuthOutcome.rejected
            : DirectAuthOutcome.pendingAuth;
      }
      if (!allowLegacyUnsignedFile) {
        return DirectAuthOutcome.rejected;
      }
      if (!fullDecrypt || !keyManager.isUnlocked) {
        return DirectAuthOutcome.pendingAuth;
      }
      try {
        await CryptoWire.decryptFileFromPeer(
          wire,
          keyManager.identity,
          peerKeys,
          allowLegacyUnsignedFile: true,
        );
        return DirectAuthOutcome.accepted;
      } catch (_) {
        return DirectAuthOutcome.rejected;
      }
    }

    if (!fullDecrypt) {
      return DirectAuthOutcome.pendingAuth;
    }

    return DirectAuthOutcome.rejected;
  }
}
