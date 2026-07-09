import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:flutter/services.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

/// Full-screen numpad PIN entry (same UX as unlock / first-time setup).
Future<String?> showPinPad({
  required BuildContext context,
  required String title,
  String? subtitle,
  Future<String?> Function(String pin)? validatePin,
}) {
  return Navigator.of(context).push<String>(
    PrysmPageRoute(
      page: PinPadScreen(
        title: title,
        subtitle: subtitle,
        validatePin: validatePin,
      ),
    ),
  );
}

/// Enter + confirm on one screen (setup-style).
Future<String?> showPinSetupPad({
  required BuildContext context,
  required String title,
  required String confirmTitle,
  String? subtitle,
  Future<String?> Function(String pin)? validatePin,
}) {
  return Navigator.of(context).push<String>(
    PrysmPageRoute(
      page: PinPadScreen(
        title: title,
        confirmTitle: confirmTitle,
        subtitle: subtitle,
        validatePin: validatePin,
      ),
    ),
  );
}

class PinPadScreen extends StatefulWidget {
  final String title;
  final String? confirmTitle;
  final String? subtitle;
  final Future<String?> Function(String pin)? validatePin;

  const PinPadScreen({
    required this.title,
    this.confirmTitle,
    this.subtitle,
    this.validatePin,
    super.key,
  });

  @override
  State<PinPadScreen> createState() => _PinPadScreenState();
}

class _PinPadScreenState extends State<PinPadScreen> {
  String _pin = '';
  String? _pendingPin;
  String? _error;
  bool _isLoading = false;

  bool get _isConfirmStep =>
      widget.confirmTitle != null && _pendingPin != null;

  String get _currentTitle {
    if (_isConfirmStep) return widget.confirmTitle!;
    return widget.title;
  }

  Future<void> _onPinFilled(String pin) async {
    if (widget.confirmTitle == null) {
      if (widget.validatePin != null) {
        setState(() => _isLoading = true);
        final validationError = await widget.validatePin!(pin);
        if (!mounted) return;
        setState(() => _isLoading = false);
        if (validationError != null) {
          setState(() {
            _error = validationError;
            _pin = '';
          });
          return;
        }
      }
      if (!mounted) return;
      Navigator.pop(context, pin);
      return;
    }

    if (_pendingPin == null) {
      if (widget.validatePin != null) {
        setState(() => _isLoading = true);
        final validationError = await widget.validatePin!(pin);
        if (!mounted) return;
        setState(() => _isLoading = false);
        if (validationError != null) {
          setState(() {
            _error = validationError;
            _pin = '';
          });
          return;
        }
      }
      setState(() {
        _pendingPin = pin;
        _pin = '';
        _error = null;
      });
      return;
    }

    if (pin != _pendingPin) {
      setState(() {
        _error = "PINs don't match";
        _pin = '';
        _pendingPin = null;
      });
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, pin);
  }

  void _onKeyPress(String key) {
    if (_isLoading) return;

    if (key == 'back') {
      if (_pin.isNotEmpty) {
        setState(() => _pin = _pin.substring(0, _pin.length - 1));
      } else if (_pendingPin != null) {
        setState(() {
          _pendingPin = null;
          _error = null;
        });
      }
      return;
    }

    if (_pin.length < 6) {
      setState(() => _pin += key);
    }

    if (_pin.length == 6) {
      final completed = _pin;
      _onPinFilled(completed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PinKeyboardListener(
      onKeyPress: _onKeyPress,
      child: PrysmPage(
        backgroundColor: context.prysmStyle.tokens.background,
        leading: PrysmIconButton(
          icon: PrysmIcons.close,
          onPressed: () => Navigator.pop(context),
        ),
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
              Text(
                _currentTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.prysmStyle.tokens.textPrimary,
                  fontWeight: FontWeight.w500,
                  fontSize: 30,
                ),
              ),
              if (widget.subtitle != null && !_isConfirmStep) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    widget.subtitle!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: context.prysmStyle.tokens.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 30),
              _isLoading
                  ? const PrysmProgressIndicator()
                  : PinDots(filledCount: _pin.length),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: context.prysmStyle.tokens.danger),
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

/// Captures physical keyboard digits and backspace for desktop PIN entry.
class PinKeyboardListener extends StatefulWidget {
  final Widget child;
  final void Function(String key) onKeyPress;

  const PinKeyboardListener({
    required this.child,
    required this.onKeyPress,
    super.key,
  });

  @override
  State<PinKeyboardListener> createState() => _PinKeyboardListenerState();
}

class _PinKeyboardListenerState extends State<PinKeyboardListener> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
      widget.onKeyPress('back');
      return KeyEventResult.handled;
    }

    final digit = _digitFromKey(key) ?? _digitFromCharacter(event.character);
    if (digit != null) {
      widget.onKeyPress(digit);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  static String? _digitFromKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      return '0';
    }
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      return '1';
    }
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      return '2';
    }
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      return '3';
    }
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      return '4';
    }
    if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
      return '5';
    }
    if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
      return '6';
    }
    if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
      return '7';
    }
    if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
      return '8';
    }
    if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
      return '9';
    }
    return null;
  }

  static String? _digitFromCharacter(String? character) {
    if (character == null || character.length != 1) return null;
    final code = character.codeUnitAt(0);
    if (code < 0x30 || code > 0x39) return null;
    return character;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: widget.child,
    );
  }
}

class PinDots extends StatelessWidget {
  final int filledCount;

  const PinDots({required this.filledCount, super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final filled = index < filledCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: filled ? 22 : 20,
          height: filled ? 22 : 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled
                ? context.prysmStyle.tokens.accent
                : context.prysmStyle.tokens.textPrimary.withAlpha(40),
          ),
        );
      }),
    );
  }
}

class PinKeypad extends StatelessWidget {
  final void Function(String key) onKeyPress;

  const PinKeypad({required this.onKeyPress, super.key});

  @override
  Widget build(BuildContext context) {
    const keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'back'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: keys.map((row) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((key) {
              if (key.isEmpty) {
                return const SizedBox(width: 80);
              } else if (key == 'back') {
                return GestureDetector(
                  onTap: () => onKeyPress('back'),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: Icon(
                      PrysmIcons.backspaceOutlined,
                      size: 28,
                      color: context.prysmStyle.tokens.textPrimary,
                    ),
                  ),
                );
              }
              return SizedBox(
                width: 80,
                height: 80,
                child: _KeyButton(
                  value: key,
                  onPressed: () => onKeyPress(key),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}

class _KeyButton extends StatelessWidget {
  final String value;
  final VoidCallback onPressed;

  const _KeyButton({required this.value, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: context.prysmStyle.tokens.textPrimary.withAlpha(15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          value,
          style: TextStyle(
            color: context.prysmStyle.tokens.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
