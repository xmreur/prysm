import 'package:flutter/material.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/util/key_manager.dart';

/// Runs the current → new → confirm passcode change flow.
/// Returns true when the PIN was updated successfully.
Future<bool> runChangePasscodeFlow(
  BuildContext context,
  KeyManager keyManager,
) async {
  final current = await showPinPad(
    context: context,
    title: 'Current passcode',
    subtitle: 'Enter your current unlock PIN.',
    validatePin: (pin) async {
      if (!await keyManager.pinUnlocksStoredKeys(pin)) {
        return 'Incorrect passcode';
      }
      return null;
    },
  );
  if (current == null || !context.mounted) return false;

  final newPin = await showPinSetupPad(
    context: context,
    title: 'New passcode',
    confirmTitle: 'Confirm new passcode',
    subtitle: 'Choose a new 6-digit unlock PIN.',
    validatePin: (pin) async {
      if (pin == current) {
        return 'New passcode must be different';
      }
      if (await PanicPinService.instance.isConfigured() &&
          await PanicPinService.instance.verify(pin)) {
        return 'Passcode cannot match your panic PIN';
      }
      return null;
    },
  );
  if (newPin == null || !context.mounted) return false;

  final ok = await keyManager.changePin(
    currentPin: current,
    newPin: newPin,
  );
  if (!context.mounted) return false;
  if (ok) {
    _showSnack(context, 'Passcode updated');
    return true;
  }
  _showSnack(context, 'Could not update passcode');
  return false;
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
