import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';

/// Outcome of an [UnlockController.verifyUnlock] attempt.
///
/// Callers apply this to their own widget state (`setState`); the
/// controller itself never touches `BuildContext`/`State`.
class UnlockOutcome {
  const UnlockOutcome({required this.unlocked, this.decoySession = false});

  /// Whether the attempt unlocked the app, either via the real
  /// passphrase/PIN or via the panic PIN.
  final bool unlocked;

  /// True when the panic PIN was used, i.e. the caller should render the
  /// decoy session instead of the real identity.
  final bool decoySession;
}

/// Owns the unlock / panic-PIN / decoy-session business logic that used to
/// live inside `_MyAppState.onVerifyUnlock` (Fase 5A extraction of
/// `lib/main.dart`).
///
/// [UnlockLockoutService] already exposes a
/// `setUseInMemoryStorageOnly`/`resetForTest` seam (see
/// `unlock_lockout_service_test.dart`), so it is used directly here just
/// like the rest of the codebase does. [PanicPinService] (secure-storage
/// backed) and [PanicWipeService.wipeAll] (destructive disk + secure
/// storage wipe) have no such seam, so they are ctor-injected instead.
class UnlockController {
  UnlockController({
    required this.keyManager,
    required this.settings,
    Future<bool> Function()? isPanicPinConfigured,
    Future<bool> Function(String pin)? verifyPanicPin,
    Future<void> Function()? wipeAll,
    Future<int> Function()? contactCount,
  })  : _isPanicPinConfigured =
            isPanicPinConfigured ?? PanicPinService.instance.isConfigured,
        _verifyPanicPin = verifyPanicPin ?? PanicPinService.instance.verify,
        _wipeAll = wipeAll ?? PanicWipeService.wipeAll,
        _contactCount = contactCount ?? _defaultContactCount;

  final KeyManager keyManager;
  final SettingsService settings;
  final Future<bool> Function() _isPanicPinConfigured;
  final Future<bool> Function(String pin) _verifyPanicPin;
  final Future<void> Function() _wipeAll;
  final Future<int> Function() _contactCount;

  static Future<int> _defaultContactCount() async =>
      (await DBHelper.getUsers()).length;

  /// Mirrors the original `_MyAppState.onVerifyUnlock` exactly: primary
  /// passphrase/PIN unlock first (with lockout bookkeeping), then the
  /// panic-PIN fallback (wipe-or-lock + decoy session). No UI/state
  /// binding here — callers apply the returned [UnlockOutcome] to their
  /// own widget state.
  Future<UnlockOutcome> verifyUnlock(String secret) async {
    final lockout = UnlockLockoutService.instance;
    final type = settings.unlockType;

    if (!await lockout.isLockedOut()) {
      if (await keyManager.unlockWithPassphrase(secret, type: type)) {
        await lockout.recordSuccess();
        await settings.migrateOnboardingIfExisting(
          readPublicKey: () =>
              keyManager.safeRead(CryptoKeyStore.publicIdentityKey),
          contactCount: await _contactCount(),
        );
        return const UnlockOutcome(unlocked: true);
      }
      await lockout.recordPrimaryFailure();
    }

    if (secret.length == 6 &&
        await _isPanicPinConfigured() &&
        await _verifyPanicPin(secret)) {
      await lockout.recordSuccess();
      if (settings.panicAction == PanicAction.wipe) {
        await _wipeAll();
        await keyManager.wipeSecureStorage();
        await settings.load();
      } else {
        keyManager.lock();
      }
      await keyManager.loadEphemeralKeys();
      return const UnlockOutcome(unlocked: true, decoySession: true);
    }

    return const UnlockOutcome(unlocked: false);
  }
}
