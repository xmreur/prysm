import 'package:flutter/material.dart';

class PinScreen extends StatefulWidget {
  final Future<bool> Function(String pin) onVerifyPin;
  final Future<bool> isSetupMode;
  const PinScreen({
    required this.onVerifyPin,
    required this.isSetupMode,
    super.key,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = "";
  String? error;
  bool isLoading = false;

  void _onKeyPress(String key) async {
    if (key == "back") {
      if (_pin.isNotEmpty) {
        setState(() => _pin = _pin.substring(0, _pin.length - 1));
      }
      return;
    }

    if (_pin.length < 6 && !isLoading) {
      setState(() => _pin += key);
    }

    if (_pin.length == 6 && !isLoading) {
      setState(() {
        isLoading = true;
        error = null;
      });

      final success = await widget.onVerifyPin(_pin);
      if (!mounted) return;
      if (!success) {
        setState(() {
          error = "Incorrect PIN";
          _pin = "";
          isLoading = false;
        });
      } else {
        setState(() {
          error = null;
          isLoading = false;
        });
      }
    }
  }

  Widget _buildPinDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final filled = index < _pin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: filled ? 22 : 20,
          height: filled ? 22 : 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface.withAlpha(40),
          ),
        );
      }),
    );
  }

  Widget _buildKey(String value) {
    return GestureDetector(
      onTap: () => _onKeyPress(value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface.withAlpha(15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          value,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 32,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    const keys = [
      ["1", "2", "3"],
      ["4", "5", "6"],
      ["7", "8", "9"],
      ["", "0", "back"],
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
              } else if (key == "back") {
                return GestureDetector(
                  onTap: () => _onKeyPress("back"),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: Icon(
                      Icons.backspace_outlined,
                      size: 28,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                );
              }
              return SizedBox(width: 80, height: 80, child: _buildKey(key));
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FutureBuilder<bool>(
                future: widget.isSetupMode,
                builder: (context, snapshot) {
                  final isSetupMode = snapshot.data ?? false;
                  return Text(
                    isSetupMode ? "Enter Passcode" : "Setup Passcode",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                      fontSize: 30,
                    ),
                  );
                },
              ),
              const SizedBox(height: 30),
              isLoading ? const CircularProgressIndicator() : _buildPinDots(),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 50),
              _buildKeypad(),
            ],
          ),
        ),
      ),
    );
  }
}
