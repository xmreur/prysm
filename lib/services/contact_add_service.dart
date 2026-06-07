import 'dart:convert';

import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/models/contact.dart';
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
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final peerOnion = onionId;
      try {
        final profileUri = Uri.parse('http://$peerOnion:80/profile');
        final profileResponse = await torClient.get(profileUri, {});
        final profileBody =
            await profileResponse.transform(utf8.decoder).join();
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
        final uri = Uri.parse('http://$peerOnion:80/public');
        final response = await torClient.get(uri, {});
        publicKeyPem =
            (await response.transform(utf8.decoder).join()).trim();
      }
    } catch (e) {
      print('Failed to fetch public key from $onionId: $e');
      return false;
    } finally {
      torClient.close();
    }

    if (publicKeyPem == null || publicKeyPem.isEmpty) {
      return false;
    }

    try {
      RSAHelper.normalizePublicKeyPem(publicKeyPem);
    } catch (e) {
      print('Invalid public key PEM from $onionId: $e');
      return false;
    }

    final newUser = Contact(
      id: onionId,
      name: fetchedName,
      avatarUrl: '',
      avatarBase64: avatarBase64,
      publicKeyPem: publicKeyPem,
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
