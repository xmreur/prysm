import 'dart:async';
import 'dart:convert';

import 'package:prysm/models/contact.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/rsa_helper.dart';

class ContactAddService {
  ContactAddService._();
  static final ContactAddService instance = ContactAddService._();

  /// Fetches peer profile over Tor and saves the contact locally.
  Future<bool> addContact({
    required String onionId,
    required String displayName,
  }) async {
    String? publicKeyPem;
    String? avatarBase64;
    String fetchedName = displayName;
    try {
      final peerOnion = onionId;
      try {
        final profileBody =
            await TransportProvider.getProfileOrFallback(peerOnion);
        final profileData = jsonDecode(profileBody) as Map<String, dynamic>;
        publicKeyPem = (profileData['publicKeyPem'] as String?)?.trim();
        if (profileData['username'] != null &&
            (profileData['username'] as String).isNotEmpty) {
          fetchedName = profileData['username'] as String;
        }
        if (profileData['avatar'] != null &&
            (profileData['avatar'] as String).isNotEmpty) {
          avatarBase64 = profileData['avatar'] as String;
        }
      } catch (e) {
        print('Profile fetch failed, trying /public: $e');
        publicKeyPem =
            (await TransportProvider.getPublicOrFallback(peerOnion)).trim();
      }
    } catch (e) {
      print('Failed to fetch public key from $onionId: $e');
      return false;
    }

    final pem = publicKeyPem?.trim();
    if (pem == null || pem.isEmpty) {
      return false;
    }

    try {
      RSAHelper.normalizePublicKeyPem(pem);
    } catch (e) {
      print('Invalid public key PEM from $onionId: $e');
      return false;
    }

    final newUser = Contact(
      id: onionId,
      name: fetchedName,
      avatarUrl: '',
      avatarBase64: avatarBase64,
      publicKeyPem: pem,
    );
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
      'avatarBase64': avatarBase64,
      'publicKeyPem': newUser.publicKeyPem,
    });
    return true;
  }
}
