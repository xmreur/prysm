import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/passphrase_entry.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/biometric_unlock_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

Future<String?> promptCurrentUnlockSecret(
  BuildContext context,
  KeyManager keyManager,
  UnlockType type,
) async {
  if (type == UnlockType.pin) {
    return showPinPad(
      context: context,
      title: context.l10n.currentPin,
      subtitle: context.l10n.enterYourCurrentUnlockPin,
      validatePin: (pin) async {
        if (!await keyManager.passphraseUnlocksStoredKeys(pin)) {
          return context.l10n.incorrectPin;
        }
        return null;
      },
    );
  }
  return showPassphraseDialog(
    context: context,
    title: context.l10n.currentPassphrase,
    subtitle: context.l10n.enterYourCurrentUnlockPassphrase,
    minLength: CryptoConstants.minPassphraseLength,
    validate: (value) async {
      if (!await keyManager.passphraseUnlocksStoredKeys(value)) {
        return context.l10n.incorrectPassphrase;
      }
      return null;
    },
  );
}

Future<String?> _promptNewSecret(
  BuildContext context,
  UnlockType type,
  String currentSecret,
) async {
  if (type == UnlockType.pin) {
    return showPinSetupPad(
      context: context,
      title: context.l10n.newPin,
      confirmTitle: context.l10n.confirmNewPin,
      subtitle: context.l10n.chooseANew6DigitPin,
      validatePin: (pin) async {
        if (pin == currentSecret) return context.l10n.newPinMustBeDifferent;
        if (!CryptoKeyStore.isValidUnlockSecret(pin, UnlockType.pin)) {
          return context.l10n.pinMustBe6Digits;
        }
        if (await PanicPinService.instance.isConfigured() &&
            await PanicPinService.instance.verify(pin)) {
          return context.l10n.pinCannotMatchYourPanicPin;
        }
        return null;
      },
    );
  }
  return showPassphraseDialog(
    context: context,
    title: context.l10n.newPassphrase,
    subtitle: context.l10n.chooseANewPassphraseAtLeast12Characters,
    confirm: true,
    minLength: CryptoConstants.minPassphraseLength,
    validate: (value) async {
      if (value == currentSecret) return context.l10n.newPassphraseMustBeDifferent;
      if (!CryptoKeyStore.isValidUnlockSecret(value, UnlockType.passphrase)) {
        return context.l10n.passphraseMustBeAtLeast12Characters;
      }
      if (await PanicPinService.instance.isConfigured() &&
          await PanicPinService.instance.verify(value)) {
        return context.l10n.passphraseCannotMatchYourPanicPin;
      }
      return null;
    },
  );
}

/// Runs the current → new → confirm unlock change flow for the active method.
Future<bool> runChangePasscodeFlow(
  BuildContext context,
  KeyManager keyManager,
) async {
  final settings = SettingsService();
  final type = settings.unlockType;

  final current = await promptCurrentUnlockSecret(context, keyManager, type);
  if (current == null || !context.mounted) return false;

  final newSecret = await _promptNewSecret(context, type, current);
  if (newSecret == null || !context.mounted) return false;

  final ok = await keyManager.changePassphrase(
    currentPassphrase: current,
    newPassphrase: newSecret,
    type: type,
  );
  if (!context.mounted) return false;
  if (ok) {
    if (settings.biometricsEnabled) {
      await BiometricUnlockService.instance.storeSecret(newSecret);
    }
    if (!context.mounted) return false;
    _showSnack(
      context,
      type == UnlockType.pin
          ? context.l10n.pinUpdated
          : context.l10n.passphraseUpdated,
    );
    return true;
  }
  _showSnack(context, context.l10n.couldNotUpdateUnlockCode);
  return false;
}

Future<bool> runUnlockMethodChange(
  BuildContext context,
  KeyManager keyManager,
  UnlockType newType,
) async {
  final settings = SettingsService();
  final oldType = settings.unlockType;
  if (newType == oldType) return true;

  final current = await promptCurrentUnlockSecret(context, keyManager, oldType);
  if (current == null || !context.mounted) return false;

  final newSecret = await _promptNewSecret(context, newType, current);
  if (newSecret == null || !context.mounted) return false;

  final ok = await keyManager.changePassphrase(
    currentPassphrase: current,
    newPassphrase: newSecret,
    type: newType,
  );
  if (!context.mounted) return false;
  if (ok) {
    await settings.setUnlockType(newType);
    if (settings.biometricsEnabled) {
      await BiometricUnlockService.instance.storeSecret(newSecret);
    }
    if (!context.mounted) return false;
    _showSnack(
      context,
      newType == UnlockType.pin
          ? context.l10n.unlockMethodSetTo6DigitPin
          : context.l10n.unlockMethodSetToPassphrase,
    );
    return true;
  }
  _showSnack(context, context.l10n.couldNotChangeUnlockMethod);
  return false;
}

void _showSnack(BuildContext context, String message) {
  showPrysmToast(context, message);
}
