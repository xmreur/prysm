import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:test/test.dart';

void main() {
  final x25519 = X25519();

  test('a sealed envelope opens to the exact bytes that went in', () async {
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final envelope = {
      'id': 'a9f1',
      'senderId': 'sender.onion',
      'receiverId': 'receiver.onion',
      'message': 'ciphertext-blob',
      'type': 'text',
      'timestamp': 1789200000000,
    };
    final plaintext = utf8.encode(jsonEncode(envelope));

    final sealed = await RelaySeal.seal(plaintext, recipientPublic.bytes);
    expect(RelaySeal.isSealed(sealed), isTrue);
    expect(sealed['scheme'], RelayProtocol.sealScheme);

    final opened = await RelaySeal.open(sealed, recipient);
    expect(jsonDecode(utf8.decode(opened)), envelope);
  });

  test('the seal hides every outer field from whoever stores it', () async {
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final sealed = await RelaySeal.seal(
      utf8.encode('{"senderId":"alice.onion","groupId":"g-1","type":"image"}'),
      recipientPublic.bytes,
    );
    final onTheWire = jsonEncode(sealed);
    expect(onTheWire, isNot(contains('alice.onion')));
    expect(onTheWire, isNot(contains('groupId')));
    expect(onTheWire, isNot(contains('image')));
    expect(sealed.keys.toSet(), {
      'crypto',
      'scheme',
      'alg',
      'ephemeralPub',
      'nonce',
      'ciphertext',
    });
  });

  test('a different key cannot open it', () async {
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final stranger = await x25519.newKeyPair();

    final sealed = await RelaySeal.seal(utf8.encode('secret'), recipientPublic.bytes);
    await expectLater(RelaySeal.open(sealed, stranger), throwsA(isA<Exception>()));
  });

  test('a flipped ciphertext byte fails authentication', () async {
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final sealed = await RelaySeal.seal(utf8.encode('secret'), recipientPublic.bytes);

    final raw = base64Decode(sealed['ciphertext'] as String);
    raw[0] = raw[0] ^ 0x01;
    final tampered = {...sealed, 'ciphertext': base64Encode(raw)};

    await expectLater(RelaySeal.open(tampered, recipient), throwsA(isA<Exception>()));
  });

  test('two seals of the same bytes differ (fresh ephemeral and nonce)', () async {
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final a = await RelaySeal.seal(utf8.encode('same'), recipientPublic.bytes);
    final b = await RelaySeal.seal(utf8.encode('same'), recipientPublic.bytes);
    expect(a['ciphertext'], isNot(b['ciphertext']));
    expect(a['ephemeralPub'], isNot(b['ephemeralPub']));
  });

  test('a malformed envelope is rejected as a bad request, not a crash', () async {
    final recipient = await x25519.newKeyPair();
    await expectLater(
      RelaySeal.open({'scheme': 'nope'}, recipient),
      throwsA(isA<RelayError>().having((e) => e.code, 'code', RelayErrorCode.badRequest)),
    );
  });
}
