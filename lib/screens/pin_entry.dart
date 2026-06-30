import 'package:flutter/material.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/screens/widgets/unlock_lockout_banner.dart';
import 'package:prysm/services/unlock_lockout_service.dart';

class PinScreen extends StatefulWidget {
  final Future<bool> Function(String pin) onVerifyPin;
  final Future<bool> isPinSet;
  final int? torBootstrapProgress;
  final bool showBiometricButton;
  final VoidCallback? onTryBiometric;

  const PinScreen({
    required this.onVerifyPin,
    required this.isPinSet,
    this.torBootstrapProgress,
    this.showBiometricButton = false,
    this.onTryBiometric,
    super.key,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String? _pendingPin;
  String? error;
  bool isLoading = false;
  bool? _pinAlreadySet;
  bool _lastFailure = false;
  bool _lockedOut = false;

  @override
  void initState() {
    super.initState();
    widget.isPinSet.then((pinSet) {
      if (mounted) setState(() => _pinAlreadySet = pinSet);
    });
    _refreshLockout();
  }

  Future<void> _refreshLockout() async {
    final locked = await UnlockLockoutService.instance.isLockedOut();
    if (mounted) setState(() => _lockedOut = locked);
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
      await _refreshLockout();
      setState(() {
        error = _isSetup
            ? 'Could not set up passcode. Try again.'
            : 'Incorrect PIN';
        _pin = '';
        _pendingPin = null;
        isLoading = false;
        _lastFailure = !_isSetup;
      });
      return;
    }

    setState(() {
      error = null;
      isLoading = false;
      _lastFailure = false;
    });
  }

  void _onKeyPress(String key) async {
    if (_lockedOut && !_isSetup) return;

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
    final inputDisabled = _lockedOut && !_isSetup;

    return PinKeyboardListener(
      onKeyPress: inputDisabled ? (_) {} : _onKeyPress,
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
                if (widget.showBiometricButton &&
                    !_isSetup &&
                    widget.onTryBiometric != null) ...[
                  const SizedBox(height: 16),
                  IconButton(
                    icon: const Icon(Icons.fingerprint, size: 48),
                    tooltip: 'Unlock with biometrics',
                    onPressed: widget.onTryBiometric,
                  ),
                ],
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
                UnlockLockoutStatus(
                  showAttemptsRemaining: !_isSetup,
                  lastFailure: _lastFailure,
                ),
                if (widget.torBootstrapProgress != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Tor: ${widget.torBootstrapProgress}%',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(160),
                    ),
                  ),
                ],
                const SizedBox(height: 50),
                Opacity(
                  opacity: inputDisabled ? 0.4 : 1,
                  child: IgnorePointer(
                    ignoring: inputDisabled,
                    child: PinKeypad(onKeyPress: _onKeyPress),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
