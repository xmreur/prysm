import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  group('TorManager.shouldClearControlSessionOnSocketDone', () {
    test('clears only when closed generation matches current', () {
      expect(
        TorManager.shouldClearControlSessionOnSocketDone(2, 2),
        isTrue,
      );
      expect(
        TorManager.shouldClearControlSessionOnSocketDone(2, 3),
        isFalse,
      );
    });

    test('stale socket done after reconnect must not clear new session', () {
      const oldSocketGeneration = 1;
      const currentGenerationAfterReconnect = 2;

      expect(
        TorManager.shouldClearControlSessionOnSocketDone(
          oldSocketGeneration,
          currentGenerationAfterReconnect,
        ),
        isFalse,
      );
    });
  });
}
