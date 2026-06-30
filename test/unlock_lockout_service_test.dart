import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/unlock_lockout_service.dart';

void main() {
  setUp(() {
    UnlockLockoutService.setUseInMemoryStorageOnly(true);
    UnlockLockoutService.resetForTest();
  });

  tearDown(() {
    UnlockLockoutService.setUseInMemoryStorageOnly(false);
  });

  test('four failures do not lock out', () async {
    final lockout = UnlockLockoutService.instance;
    for (var i = 0; i < 4; i++) {
      await lockout.recordPrimaryFailure();
    }
    expect(await lockout.isLockedOut(), isFalse);
    expect(await lockout.attemptsRemaining(), 1);
  });

  test('fifth failure locks for two hours', () async {
    final lockout = UnlockLockoutService.instance;
    for (var i = 0; i < 5; i++) {
      await lockout.recordPrimaryFailure();
    }
    expect(await lockout.isLockedOut(), isTrue);
    final remaining = await lockout.remainingLockout();
    expect(remaining, isNotNull);
    expect(remaining!.inMinutes, greaterThanOrEqualTo(119));
    expect(await lockout.attemptsRemaining(), 0);
  });

  test('success clears failure state', () async {
    final lockout = UnlockLockoutService.instance;
    await lockout.recordPrimaryFailure();
    await lockout.recordPrimaryFailure();
    await lockout.recordSuccess();
    expect(await lockout.attemptsRemaining(), UnlockLockoutService.maxAttempts);
    expect(await lockout.isLockedOut(), isFalse);
  });

  test('failures while locked are ignored', () async {
    final lockout = UnlockLockoutService.instance;
    for (var i = 0; i < 5; i++) {
      await lockout.recordPrimaryFailure();
    }
    await lockout.recordPrimaryFailure();
    expect(await lockout.isLockedOut(), isTrue);
  });
}
