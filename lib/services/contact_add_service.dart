import 'dart:async';
import 'dart:convert';

import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/logging.dart';

class ContactAddService {
  ContactAddService._();
  static final ContactAddService instance = ContactAddService._();

  Future<bool> addContact({
    required String onionId,
    required String displayName,
    String? expectedFingerprint,
  }) async {
    if (BlockService.instance.isBlocked(onionId)) {
      Logging.error('Cannot add blocked contact $onionId', 'ContactAddService');
      return false;
    }
    String? identityJson;
    String? avatarBase64;
    String fetchedName = displayName;
    try {
      final peerOnion = onionId;
      try {
        final profileBody =
            await TransportProvider.getProfileOrFallback(peerOnion);
        final profileData = jsonDecode(profileBody) as Map<String, dynamic>;
        identityJson = (profileData['identityJson'] as String?)?.trim() ??
            (profileData['publicKeyPem'] as String?)?.trim();
        if (profileData['username'] != null &&
            (profileData['username'] as String).isNotEmpty) {
          fetchedName = profileData['username'] as String;
        }
        if (profileData['avatar'] != null &&
            (profileData['avatar'] as String).isNotEmpty) {
          avatarBase64 = profileData['avatar'] as String;
        }
      } catch (e) {
        Logging.error('Profile fetch failed, trying /public: $e', 'ContactAddService');
        identityJson =
            (await TransportProvider.getPublicOrFallback(peerOnion)).trim();
      }
    } catch (e) {
      Logging.error('Failed to fetch identity from $onionId: $e', 'ContactAddService');
      return false;
    }

    final json = identityJson?.trim();
    if (json == null || json.isEmpty) {
      return false;
    }

    IdentityPublicKeys keys;
    try {
      keys = IdentityKeyPair.parsePublicJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
    } catch (e) {
      Logging.error('Invalid identity JSON from $onionId: $e', 'ContactAddService');
      return false;
    }

    if (expectedFingerprint != null &&
        keys.fingerprint != expectedFingerprint) {
      Logging.error('Identity fingerprint mismatch for $onionId', 'ContactAddService');
      return false;
    }

    final newUser = Contact(
      id: onionId,
      name: fetchedName,
      avatarUrl: '',
      avatarBase64: avatarBase64,
      identityJson: json,
    );
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
      'avatarBase64': avatarBase64,
      'identityJson': json,
      'publicKeyPem': json,
    });
    return true;
  }
}
