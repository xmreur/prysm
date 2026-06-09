import 'package:flutter/material.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';

class PinScreen extends StatefulWidget {
  final Future<bool> Function(String pin) onVerifyPin;
  final Future<bool> isPinSet;
  final int? torBootstrapProgress;

  const PinScreen({
    required this.onVerifyPin,
    required this.isPinSet,
    this.torBootstrapProgress,
    super.key,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = "";
  String? _pendingPin;
  String? error;
  bool isLoading = false;
  bool? _pinAlreadySet;

  @override
  void initState() {
    super.initState();
    widget.isPinSet.then((pinSet) {
      if (mounted) setState(() => _pinAlreadySet = pinSet);
    });
  }

  bool get _isSetup => _pinAlreadySet == false;
  bool get _isConfirmingSetup => _isSetup && _pendingPin != null;

  String get _title {
    if (_pinAlreadySet == null) return '';
    if (_isConfirmingSetup) return 'Confirm Passcode';
    if (_isSetup) return 'Setup Passcode';
    return 'Enter Passcode';
  }

  Future<void> _submitPin(String pin) async {
    setState(() {
      isLoading = true;
      error = null;
    });

    final success = await widget.onVerifyPin(pin);
    if (!mounted) return;

    if (!success) {
      setState(() {
        error = _isSetup
            ? 'Could not set up passcode. Try again.'
            : 'Incorrect PIN';
        _pin = '';
        _pendingPin = null;
        isLoading = false;
      });
      return;
    }

    setState(() {
      error = null;
      isLoading = false;
    });
  }

  void _onKeyPress(String key) async {
    if (key == 'back') {
      if (_pin.isNotEmpty) {
        setState(() => _pin = _pin.substring(0, _pin.length - 1));
      } else if (_pendingPin != null) {
        setState(() {
          _pendingPin = null;
          error = null;
        });
      }
      return;
    }

    if (_pin.length < 6 && !isLoading) {
      setState(() => _pin += key);
    }

    if (_pin.length == 6 && !isLoading) {
      if (_isSetup) {
        if (_pendingPin == null) {
          setState(() {
            _pendingPin = _pin;
            _pin = '';
            error = null;
          });
          return;
        }

        if (_pin != _pendingPin) {
          setState(() {
            error = "PINs don't match";
            _pin = '';
            _pendingPin = null;
          });
          return;
        }

        await _submitPin(_pin);
        return;
      }

      await _submitPin(_pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PinKeyboardListener(
      onKeyPress: _onKeyPress,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
              Text(
                _title,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  fontSize: 30,
                ),
              ),
              const SizedBox(height: 30),
              isLoading
                  ? const CircularProgressIndicator()
                  : PinDots(filledCount: _pin.length),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (widget.torBootstrapProgress != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Tor: ${widget.torBootstrapProgress}%',
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        Theme.of(context).colorScheme.onSurface.withAlpha(160),
                  ),
                ),
              ],
              const SizedBox(height: 50),
              PinKeypad(onKeyPress: _onKeyPress),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
