import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<String?> showSixDigitPinDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SixDigitPinDialog(
      title: title,
      subtitle: subtitle,
    ),
  );
}

class _SixDigitPinDialog extends StatefulWidget {
  final String title;
  final String? subtitle;

  const _SixDigitPinDialog({
    required this.title,
    this.subtitle,
  });

  @override
  State<_SixDigitPinDialog> createState() => _SixDigitPinDialogState();
}

class _SixDigitPinDialogState extends State<_SixDigitPinDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text;
    if (pin.length != 6 || !RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _error = 'Enter a 6-digit PIN');
      return;
    }
    Navigator.pop(context, pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.subtitle != null) ...[
            Text(widget.subtitle!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            autofocus: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '6-digit PIN',
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
