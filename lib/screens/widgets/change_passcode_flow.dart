import 'package:flutter/material.dart';
import 'package:prysm/screens/passphrase_entry.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/util/key_manager.dart';

/// Runs the current → new → confirm passphrase change flow.
/// Returns true when the passphrase was updated successfully.
Future<bool> runChangePasscodeFlow(
  BuildContext context,
  KeyManager keyManager,
) async {
  final current = await showPassphraseDialog(
    context: context,
    title: 'Current passphrase',
    subtitle: 'Enter your current unlock passphrase.',
    validate: (value) async {
      if (!await keyManager.passphraseUnlocksStoredKeys(value)) {
        return 'Incorrect passphrase';
      }
      return null;
    },
  );
  if (current == null || !context.mounted) return false;

  final newPassphrase = await showPassphraseDialog(
    context: context,
    title: 'New passphrase',
    subtitle: 'Choose a new passphrase (at least 12 characters).',
    confirm: true,
    validate: (value) async {
      if (value == current) {
        return 'New passphrase must be different';
      }
      if (await PanicPinService.instance.isConfigured() &&
          await PanicPinService.instance.verify(value)) {
        return 'Passphrase cannot match your panic PIN';
      }
      return null;
    },
  );
  if (newPassphrase == null || !context.mounted) return false;

  final ok = await keyManager.changePassphrase(
    currentPassphrase: current,
    newPassphrase: newPassphrase,
  );
  if (!context.mounted) return false;
  if (ok) {
    _showSnack(context, 'Passphrase updated');
    return true;
  }
  _showSnack(context, 'Could not update passphrase');
  return false;
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
