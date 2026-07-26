// Targeted tests for the pure MessageIdCodec module (Fase 4A step 4).
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_id_codec.dart';

void main() {
  group('scopedId', () {
    test('prefixes the wireId with groupId when present', () {
      expect(MessageIdCodec.scopedId(wireId: 'w1', groupId: 'g1'), 'g1::w1');
    });

    test('returns the wireId unchanged without a groupId', () {
      expect(MessageIdCodec.scopedId(wireId: 'w1'), 'w1');
    });

    test('returns the wireId unchanged for an empty-string groupId', () {
      expect(MessageIdCodec.scopedId(wireId: 'w1', groupId: ''), 'w1');
    });
  });

  group('wireIdFromStorage', () {
    test('strips the groupId scope', () {
      expect(MessageIdCodec.wireIdFromStorage('g1::w1'), 'w1');
    });

    test('returns an unscoped id unchanged', () {
      expect(MessageIdCodec.wireIdFromStorage('w1'), 'w1');
    });

    test('only strips the first separator', () {
      expect(MessageIdCodec.wireIdFromStorage('g1::w1::extra'), 'w1::extra');
    });
  });

  test('round-trips through scopedId/wireIdFromStorage', () {
    final scoped = MessageIdCodec.scopedId(wireId: 'abc', groupId: 'g1');
    expect(MessageIdCodec.wireIdFromStorage(scoped), 'abc');
  });
}
