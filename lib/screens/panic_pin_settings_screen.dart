import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/models/panic_action.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_radio.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

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
    var selected = _action;
    final picked = await showPrysmSheet<PanicAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setModalState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in PanicAction.values)
                  PrysmRadioRow<PanicAction>(
                    value: action,
                    groupValue: selected,
                    title: action.label,
                    subtitle: action.description,
                    onChanged: (value) {
                      if (value == null) return;
                      setModalState(() => selected = value);
                      Navigator.pop(ctx, value);
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    await _settings.setPanicAction(picked);
    if (!mounted) return;
    setState(() => _action = picked);
  }

  void _showSnack(String message) {
    showPrysmToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmPage(
      title: 'Panic mode',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'A panic PIN is a second passcode. Entering it at unlock '
                      'never reveals your real chats. Configure what happens '
                      'when it is used.',
                      style: context.prysmStyle.bodyStyle,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                PrysmListRow(
                  leading: Icon(
                    _configured ? PrysmIcons.shieldOutlined : PrysmIcons.shield,
                    color: _configured ? tokens.accent : tokens.textMuted,
                  ),
                  title: _configured ? 'Panic PIN is set' : 'Panic PIN not set',
                  subtitle: _configured
                      ? 'Secondary PIN is active'
                      : 'Set a panic PIN to enable panic mode',
                ),
                const PrysmDivider(),
                PrysmListRow(
                  leading: const Icon(PrysmIcons.emergencyOutlined),
                  title: 'When panic PIN is used',
                  subtitle: _action.description,
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: _pickAction,
                ),
                const PrysmDivider(),
                if (!_configured)
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.addModeratorOutlined),
                    title: 'Set panic PIN',
                    onTap: _setPanicPin,
                  )
                else ...[
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.pin),
                    title: 'Change panic PIN',
                    onTap: _changePanicPin,
                  ),
                  PrysmListRow(
                    leading: Icon(PrysmIcons.deleteOutline, color: tokens.danger),
                    titleWidget: Text(
                      'Remove panic PIN',
                      style: TextStyle(color: tokens.danger),
                    ),
                    onTap: _removePanicPin,
                  ),
                ],
              ],
            ),
    );
  }
}
