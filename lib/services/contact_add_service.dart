import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/transport/transport_preference.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/logging.dart';

class ContactAddService {
  /// [fetchPublic]/[fetchProfile] default to [TransportProvider]'s Tor
  /// helpers with this service's own timeout/preference/attempt budget
  /// baked in (mirrors [PeerIdentityResolver]'s fetch-injection pattern);
  /// tests inject fakes here instead of hitting the network. Optional so
  /// [instance] and every existing consumer are unaffected.
  ContactAddService._({
    Future<String> Function(String onionId)? fetchPublic,
    Future<String> Function(String onionId)? fetchProfile,
  })  : _fetchPublic = fetchPublic ?? _defaultFetchPublic,
        _fetchProfile = fetchProfile ?? _defaultFetchProfile;

  static final ContactAddService instance = ContactAddService._();

  /// Test-only constructor for injecting fake fetch functions. Production
  /// code always goes through [instance]; mirrors the visibleForTesting
  /// factory pattern already used by CallSignalingNotifier for
  /// private-ctor singletons.
  @visibleForTesting
  factory ContactAddService.forTesting({
    Future<String> Function(String onionId)? fetchPublic,
    Future<String> Function(String onionId)? fetchProfile,
  }) =>
      ContactAddService._(
        fetchPublic: fetchPublic,
        fetchProfile: fetchProfile,
      );

  static const Duration _fetchTimeout = Duration(seconds: 12);
  static const int _fetchMaxAttempts = 2;
  static const Duration _profileEnrichTimeout = Duration(seconds: 20);

  final Future<String> Function(String onionId) _fetchPublic;
  final Future<String> Function(String onionId) _fetchProfile;

  static Future<String> _defaultFetchPublic(String onionId) =>
      TransportProvider.getPublicOrFallback(
        onionId,
        timeout: _fetchTimeout,
        preference: TransportPreference.httpOnly,
        maxAttempts: _fetchMaxAttempts,
      );

  static Future<String> _defaultFetchProfile(String onionId) =>
      TransportProvider.getProfileOrFallback(
        onionId,
        timeout: _profileEnrichTimeout,
        preference: TransportPreference.httpOnly,
        maxAttempts: 1,
      );

  Future<bool> addContact({
    required String onionId,
    required String displayName,
    String? expectedFingerprint,
  }) async {
    if (BlockService.instance.isBlocked(onionId)) {
      Logging.error('Cannot add blocked contact $onionId', 'ContactAddService');
      return false;
    }

    String identityJson;
    try {
      identityJson = (await _fetchPublic(onionId)).trim();
    } catch (e) {
      Logging.error('Failed to fetch identity from $onionId: $e', 'ContactAddService');
      return false;
    }

    if (identityJson.isEmpty) {
      return false;
    }

    IdentityPublicKeys keys;
    try {
      keys = IdentityKeyPair.parsePublicJson(
        jsonDecode(identityJson) as Map<String, dynamic>,
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
      name: displayName,
      avatarUrl: '',
      avatarBase64: null,
      identityJson: identityJson,
    );
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
      'avatarBase64': null,
      'identityJson': identityJson,
      'publicKeyPem': identityJson,
    });

    unawaited(_enrichFromProfile(onionId));
    return true;
  }

  Future<void> _enrichFromProfile(String onionId) async {
    try {
      final profileBody = await _fetchProfile(onionId);
      final profileData = jsonDecode(profileBody) as Map<String, dynamic>;
      final identityJson = IdentityKeyPair.storedPeerIdentityRaw(
        (profileData['identityJson'] as String?)?.trim(),
        (profileData['publicKeyPem'] as String?)?.trim(),
      );
      if (identityJson == null || identityJson.isEmpty) {
        return;
      }

      final updates = <String, dynamic>{};
      final username = profileData['username'] as String?;
      if (username != null && username.isNotEmpty) {
        updates['name'] = username;
      }
      final avatar = profileData['avatar'] as String?;
      if (avatar != null && avatar.isNotEmpty) {
        updates['avatarBase64'] = avatar;
      }
      if (updates.isEmpty) {
        return;
      }

      final existing = await DBHelper.getUserById(onionId);
      if (existing == null) {
        return;
      }

      await DBHelper.updateUserFields(onionId, updates);
      ConversationRefreshNotifier.instance.notifyInboundMessage();
    } catch (e) {
      Logging.error(
        'Profile enrichment failed for $onionId: $e',
        'ContactAddService',
      );
    }
  }
}
