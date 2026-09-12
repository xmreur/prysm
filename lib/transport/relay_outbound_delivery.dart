import 'dart:convert';

import 'package:prysm/crypto/identity.dart';
import 'package:prysm/transport/relay_client.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/relay_store.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

/// Depositing an outbound message at the *recipient's* relay.
///
/// The envelope is sealed unchanged, so at pickup the recipient replays it into
/// its own inbound pipeline byte-identical. Nothing here knows what a message
/// is: it takes the same payload the direct path would have posted.
class RelayOutboundDelivery {
  RelayOutboundDelivery._();

  /// Tries the peer's relay. Returns true only when the relay accepted the
  /// deposit; every failure answers false, because the caller still holds the
  /// message in its local pending queue and direct delivery remains the plan.
  static Future<bool> tryDeposit({
    required String peerOnion,
    required Map<String, dynamic> payload,
    Duration timeout = RelayClient.defaultTimeout,
  }) async {
    try {
      final advert = await PeerRelayStore.load(peerOnion);
      if (advert == null || advert.isEmpty) return false;
      if (advert.expiredAt(DateTime.now())) {
        Logging.debug(
          'Relay advertisement expired for ${Logging.redactOnion(peerOnion)}',
          'RelayOutbound',
        );
        return false;
      }
      final endpoint = advert.preferred;
      if (endpoint == null) return false;

      final identity = await _peerIdentity(peerOnion);
      if (identity == null) return false;

      // A cached advertisement is worth exactly what its signature proves.
      final signatureOk = await advert.verify(
        ownerFingerprint: identity.fingerprint,
        ownerSignPublicKey: identity.signPublic.bytes,
      );
      if (!signatureOk) {
        Logging.error(
          'Relay advertisement signature invalid for '
          '${Logging.redactOnion(peerOnion)} — ignoring it',
          'RelayOutbound',
        );
        return false;
      }

      final plaintext = utf8.encode(jsonEncode(payload));
      if (plaintext.length > endpoint.maxItemBytes) {
        Logging.debug(
          'Payload ${plaintext.length}B over the relay cap '
          '${endpoint.maxItemBytes}B — keeping it for direct delivery',
          'RelayOutbound',
        );
        return false;
      }

      final sealed = await RelaySeal.seal(plaintext, identity.agreePublic.bytes);
      final client = RelayClient(relayOnion: endpoint.onion);
      await client.deposit(
        deposit: endpoint.deposit,
        payload: sealed,
        timeout: timeout,
      );
      Logging.debug(
        'Deposited ${plaintext.length}B at the relay of '
        '${Logging.redactOnion(peerOnion)}',
        'RelayOutbound',
      );
      return true;
    } on RelayError catch (e) {
      Logging.error('Relay refused the deposit: ${e.code}', 'RelayOutbound');
      return false;
    } catch (e) {
      Logging.error('Relay deposit failed: $e', 'RelayOutbound');
      return false;
    }
  }

  static Future<IdentityPublicKeys?> _peerIdentity(String peerOnion) async {
    try {
      final row = await DBHelper.getUserById(peerOnion);
      final raw = (row?['identityJson'] as String?)?.trim();
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return IdentityKeyPair.parsePublicJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // A legacy PEM identity cannot be sealed to: a peer that never published
      // a v2 identity cannot have published an advertisement either.
      return null;
    }
  }
}
