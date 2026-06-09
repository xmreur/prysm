import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/tor_delivery.dart';
import 'package:prysm/util/tor_service.dart';

void main() {
  setUp(TorDelivery.resetForTest);

  group('TorDelivery.isRetryableError', () {
    test('treats timeout as retryable', () {
      expect(TorDelivery.isRetryableError(TimeoutException('x')), isTrue);
    });

    test('treats ttlExpired as retryable', () {
      expect(
        TorDelivery.isRetryableError(Exception('ttlExpired')),
        isTrue,
      );
    });

    test('treats HttpException connection closed as circuit error', () {
      final error = HttpException(
        'Connection closed while receiving data',
        uri: Uri.parse('http://peer.onion/profile'),
      );
      expect(TorDelivery.isRetryableError(error), isTrue);
      expect(TorDelivery.isCircuitError(error), isTrue);
    });

    test('treats hostUnreachable as retryable circuit error', () {
      expect(
        TorDelivery.isRetryableError(
          Exception(
            'SocksClientConnectionCommandFailedException: hostUnreachable',
          ),
        ),
        isTrue,
      );
      expect(
        TorDelivery.isCircuitError(
          Exception(
            'SocksClientConnectionCommandFailedException: hostUnreachable',
          ),
        ),
        isTrue,
      );
    });

    test('treats unknown errors as non-retryable', () {
      expect(
        TorDelivery.isRetryableError(Exception('permission denied')),
        isFalse,
      );
    });
  });

  group('TorDelivery.withTorRetry', () {
    test('returns immediately on success', () async {
      final result = await TorDelivery.withTorRetry<int>(
        attempt: () async => 42,
      );
      expect(result, 42);
    });

    test('retries retryable errors', () async {
      var attempts = 0;
      final result = await TorDelivery.withTorRetry<int>(
        maxAttempts: 2,
        attempt: () async {
          attempts++;
          if (attempts == 1) {
            throw TimeoutException('send');
          }
          return 7;
        },
      );
      expect(result, 7);
      expect(attempts, 2);
    });

    test('retries up to three times by default', () async {
      var attempts = 0;
      await expectLater(
        TorDelivery.withTorRetry<void>(
          attempt: () async {
            attempts++;
            throw Exception('hostUnreachable');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 3);
    });

    test('does not call refresh when NEWNYM was recent', () async {
      TorDelivery.configure(
        TorManager(torPath: '/bin/false', dataDir: '/tmp/tor-delivery'),
      );
      TorDelivery.setLastNewnymForTest(
        DateTime.now().subtract(const Duration(seconds: 2)),
      );

      var attempts = 0;
      await TorDelivery.withTorRetry<void>(
        attempt: () async {
          attempts++;
          if (attempts == 1) {
            throw TimeoutException('send');
          }
        },
      );
      expect(attempts, 2);
    });
  });
}
