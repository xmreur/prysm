import 'dart:convert';

import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/onion_id_codec.dart';

enum VerificationStatus { unverified, verified, keyChanged }

class ContactVerificationService {
  ContactVerificationService._();

  static final ContactVerificationService instance =
      ContactVerificationService._();

  String? fingerprintFor(Contact contact) {
    final raw = contact.identityJson.trim();
    if (raw.isEmpty || raw == 'NONE') return null;
    try {
      return IdentityKeyPair.fingerprintFromPublicJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  VerificationStatus statusFor(Contact contact) {
    final current = fingerprintFor(contact);
    if (current == null) {
      return VerificationStatus.unverified;
    }
    final verified = contact.verifiedFingerprint;
    if (verified == null || verified.isEmpty) {
      return VerificationStatus.unverified;
    }
    if (current == verified) {
      return VerificationStatus.verified;
    }
    return VerificationStatus.keyChanged;
  }

  String formatFingerprint(String hex) {
    final normalized = hex.toLowerCase();
    final buffer = StringBuffer();
    for (var i = 0; i < normalized.length; i += 8) {
      if (i > 0) buffer.write(' ');
      final end = (i + 8 < normalized.length) ? i + 8 : normalized.length;
      buffer.write(normalized.substring(i, end));
    }
    return buffer.toString();
  }

  String statusLabel(VerificationStatus status) {
    switch (status) {
      case VerificationStatus.unverified:
        return 'Not verified';
      case VerificationStatus.verified:
        return 'Verified';
      case VerificationStatus.keyChanged:
        return 'Key changed';
    }
  }

  Future<void> markVerified(String contactId, String fingerprint) async {
    await DBHelper.updateUserFields(contactId, {
      'verifiedFingerprint': fingerprint,
    });
  }

  Future<void> clearVerification(String contactId) async {
    await DBHelper.updateUserFields(contactId, {'verifiedFingerprint': null});
  }

  bool qrMatchesContact(QrPayload payload, Contact contact) {
    try {
      final decodedOnion = decodeBase58ToOnion(payload.onion);
      if (decodedOnion != contact.id) return false;
    } catch (_) {
      return false;
    }
    final current = fingerprintFor(contact);
    if (current == null) return false;
    return payload.fingerprint == current;
  }
}
