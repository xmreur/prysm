import 'package:flutter/material.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/util/key_manager.dart';

class PanicPinSettingsScreen extends StatefulWidget {
  final KeyManager keyManager;
  final VoidCallback onClose;

  const PanicPinSettingsScreen({
    required this.keyManager,
    required this.onClose,
    super.key,
  });

  @override
  State<PanicPinSettingsScreen> createState() => _PanicPinSettingsScreenState();
}

class _PanicPinSettingsScreenState extends State<PanicPinSettingsScreen> {
  final _settings = SettingsService();
  bool _configured = false;
  bool _loading = true;
  late PanicAction _action;

  @override
  void initState() {
    super.initState();
    _action = _settings.panicAction;
    _refresh();
  }

  Future<void> _refresh() async {
    final configured = await PanicPinService.instance.isConfigured();
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _action = _settings.panicAction;
      _loading = false;
    });
  }

  Future<String?> _validateNewPanicPin(String pin) async {
    if (await widget.keyManager.pinUnlocksStoredKeys(pin)) {
      return 'Panic PIN cannot match your main passcode';
    }
    return null;
  }

  Future<void> _setPanicPin() async {
    final pin = await showPinSetupPad(
      context: context,
      title: 'Set panic PIN',
      confirmTitle: 'Confirm panic PIN',
      subtitle: 'This is your secondary PIN for emergency use.',
      validatePin: _validateNewPanicPin,
    );
    if (pin == null || !mounted) return;

    await PanicPinService.instance.setPin(pin);
    if (!mounted) return;
    _showSnack('Panic PIN saved');
    await _refresh();
  }

  Future<void> _changePanicPin() async {
    final current = await showPinPad(
      context: context,
      title: 'Current panic PIN',
      validatePin: (pin) async {
        if (!await PanicPinService.instance.verify(pin)) {
          return 'Incorrect panic PIN';
        }
        return null;
      },
    );
    if (current == null || !mounted) return;

    final pin = await showPinSetupPad(
      context: context,
      title: 'New panic PIN',
      confirmTitle: 'Confirm new panic PIN',
      validatePin: _validateNewPanicPin,
    );
    if (pin == null || !mounted) return;

    await PanicPinService.instance.setPin(pin);
    if (!mounted) return;
    _showSnack('Panic PIN updated');
    await _refresh();
  }

  Future<void> _removePanicPin() async {
    final current = await showPinPad(
      context: context,
      title: 'Enter panic PIN to remove',
      validatePin: (pin) async {
        if (!await PanicPinService.instance.verify(pin)) {
          return 'Incorrect panic PIN';
        }
        return null;
      },
    );
    if (current == null || !mounted) return;

    await PanicPinService.instance.clear();
    if (!mounted) return;
    _showSnack('Panic PIN removed');
    await _refresh();
  }

  Future<void> _pickAction() async {
    final selected = await showModalBottomSheet<PanicAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<PanicAction>(
          groupValue: _action,
          onChanged: (value) => Navigator.pop(ctx, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: PanicAction.values.map((action) {
              return RadioListTile<PanicAction>(
                value: action,
                title: Text(action.label),
                subtitle: Text(action.description),
              );
            }).toList(),
          ),
        ),
      ),
    );
    if (selected == null) return;
    await _settings.setPanicAction(selected);
    if (!mounted) return;
    setState(() => _action = selected);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panic mode'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onClose,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'A panic PIN is a second passcode. Entering it at unlock '
                      'never reveals your real chats. Configure what happens '
                      'when it is used.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(
                    _configured ? Icons.shield_outlined : Icons.shield,
                    color: _configured
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).hintColor,
                  ),
                  title: Text(_configured ? 'Panic PIN is set' : 'Panic PIN not set'),
                  subtitle: Text(
                    _configured
                        ? 'Secondary PIN is active'
                        : 'Set a panic PIN to enable panic mode',
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.emergency_outlined),
                  title: const Text('When panic PIN is used'),
                  subtitle: Text(_action.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickAction,
                ),
                const Divider(),
                if (!_configured)
                  ListTile(
                    leading: const Icon(Icons.add_moderator_outlined),
                    title: const Text('Set panic PIN'),
                    onTap: _setPanicPin,
                  )
                else ...[
                  ListTile(
                    leading: const Icon(Icons.pin_outlined),
                    title: const Text('Change panic PIN'),
                    onTap: _changePanicPin,
                  ),
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: Colors.red[400]),
                    title: Text(
                      'Remove panic PIN',
                      style: TextStyle(color: Colors.red[400]),
                    ),
                    onTap: _removePanicPin,
                  ),
                ],
              ],
            ),
    );
  }
}
