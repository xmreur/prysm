import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/qr_payload.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/services/contact_verification_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      name TEXT,
      avatarUrl TEXT,
      avatarBase64 TEXT,
      customName TEXT,
      publicKeyPem TEXT,
      identityJson TEXT,
      ratchetScheme TEXT,
      verifiedFingerprint TEXT
    )
  ''');
  return db;
}

Future<Contact> _contactWithIdentity({
  String id = 'peer.onion',
  String? verifiedFingerprint,
}) async {
  final identity = await IdentityKeyPair.generate();
  final identityJson = jsonEncode(await identity.toPublicJson());
  return Contact(
    id: id,
    name: 'Peer',
    avatarUrl: '',
    identityJson: identityJson,
    verifiedFingerprint: verifiedFingerprint,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  final service = ContactVerificationService.instance;

  setUp(() async {
    db = await _openTestDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('statusFor', () {
    test('unverified when verifiedFingerprint is null', () async {
      final contact = await _contactWithIdentity();
      expect(service.statusFor(contact), VerificationStatus.unverified);
    });

    test('verified when fingerprints match', () async {
      final contact = await _contactWithIdentity();
      final fingerprint = service.fingerprintFor(contact)!;
      final verified = contact.copyWith(verifiedFingerprint: fingerprint);
      expect(service.statusFor(verified), VerificationStatus.verified);
    });

    test('keyChanged when verified fingerprint differs', () async {
      final contact = await _contactWithIdentity(
        verifiedFingerprint: 'a' * 64,
      );
      expect(service.statusFor(contact), VerificationStatus.keyChanged);
    });
  });

  group('formatFingerprint', () {
    test('groups hex into chunks of eight', () {
      final formatted = service.formatFingerprint('a' * 64);
      expect(formatted.split(' ').length, 8);
      expect(formatted.replaceAll(' ', '').length, 64);
    });
  });

  group('qrMatchesContact', () {
    test('matches when onion and fingerprint align', () async {
      final contact = await _contactWithIdentity(id: 'abc123.onion');
      final fingerprint = service.fingerprintFor(contact)!;
      final payload = QrPayload(
        onion: encodeOnionToBase58('abc123.onion'),
        fingerprint: fingerprint,
      );
      expect(service.qrMatchesContact(payload, contact), isTrue);
    });

    test('rejects mismatched fingerprint', () async {
      final contact = await _contactWithIdentity(id: 'abc123.onion');
      final payload = QrPayload(
        onion: encodeOnionToBase58('abc123.onion'),
        fingerprint: 'b' * 64,
      );
      expect(service.qrMatchesContact(payload, contact), isFalse);
    });

    test('rejects mismatched onion', () async {
      final contact = await _contactWithIdentity(id: 'abc123.onion');
      final fingerprint = service.fingerprintFor(contact)!;
      final payload = QrPayload(
        onion: encodeOnionToBase58('other.onion'),
        fingerprint: fingerprint,
      );
      expect(service.qrMatchesContact(payload, contact), isFalse);
    });
  });

  group('markVerified / clearVerification', () {
    test('persists and clears verifiedFingerprint in DB', () async {
      const contactId = 'peer.onion';
      await db.insert('users', {
        'id': contactId,
        'name': 'Peer',
        'avatarUrl': '',
      });

      final fingerprint = 'deadbeef' * 8;
      await service.markVerified(contactId, fingerprint);

      final row = await DBHelper.getUserById(contactId);
      expect(row!['verifiedFingerprint'], fingerprint);

      await service.clearVerification(contactId);
      final cleared = await DBHelper.getUserById(contactId);
      expect(cleared!['verifiedFingerprint'], isNull);
    });
  });
}
