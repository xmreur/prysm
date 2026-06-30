import 'package:flutter/material.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/passphrase_entry.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';

Future<String?> _promptCurrentSecret(
  BuildContext context,
  KeyManager keyManager,
  UnlockType type,
) async {
  if (type == UnlockType.pin) {
    return showPinPad(
      context: context,
      title: 'Current PIN',
      subtitle: 'Enter your current unlock PIN.',
      validatePin: (pin) async {
        if (!await keyManager.passphraseUnlocksStoredKeys(pin)) {
          return 'Incorrect PIN';
        }
        return null;
      },
    );
  }
  return showPassphraseDialog(
    context: context,
    title: 'Current passphrase',
    subtitle: 'Enter your current unlock passphrase.',
    minLength: CryptoConstants.minPassphraseLength,
    validate: (value) async {
      if (!await keyManager.passphraseUnlocksStoredKeys(value)) {
        return 'Incorrect passphrase';
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
      title: 'New PIN',
      confirmTitle: 'Confirm new PIN',
      subtitle: 'Choose a new 6-digit PIN.',
      validatePin: (pin) async {
        if (pin == currentSecret) return 'New PIN must be different';
        if (!CryptoKeyStore.isValidUnlockSecret(pin, UnlockType.pin)) {
          return 'PIN must be 6 digits';
        }
        if (await PanicPinService.instance.isConfigured() &&
            await PanicPinService.instance.verify(pin)) {
          return 'PIN cannot match your panic PIN';
        }
        return null;
      },
    );
  }
  return showPassphraseDialog(
    context: context,
    title: 'New passphrase',
    subtitle: 'Choose a new passphrase (at least 12 characters).',
    confirm: true,
    minLength: CryptoConstants.minPassphraseLength,
    validate: (value) async {
      if (value == currentSecret) return 'New passphrase must be different';
      if (!CryptoKeyStore.isValidUnlockSecret(value, UnlockType.passphrase)) {
        return 'Passphrase must be at least 12 characters';
      }
      if (await PanicPinService.instance.isConfigured() &&
          await PanicPinService.instance.verify(value)) {
        return 'Passphrase cannot match your panic PIN';
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

  final current = await _promptCurrentSecret(context, keyManager, type);
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
    _showSnack(
      context,
      type == UnlockType.pin ? 'PIN updated' : 'Passphrase updated',
    );
    return true;
  }
  _showSnack(context, 'Could not update unlock code');
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

  final current = await _promptCurrentSecret(context, keyManager, oldType);
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
    _showSnack(
      context,
      newType == UnlockType.pin
          ? 'Unlock method set to 6-digit PIN'
          : 'Unlock method set to passphrase',
    );
    return true;
  }
  _showSnack(context, 'Could not change unlock method');
  return false;
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
