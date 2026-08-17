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
import 'package:prysm/l10n/l10n_enum_extensions.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

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
      return context.l10n.panicPinCannotMatchYourMainPasscode;
    }
    return null;
  }

  Future<void> _setPanicPin() async {
    final pin = await showPinSetupPad(
      context: context,
      title: context.l10n.setPanicPin,
      confirmTitle: context.l10n.confirmPanicPin,
      subtitle: context.l10n.thisIsYourSecondaryPinForEmergencyUse,
      validatePin: _validateNewPanicPin,
    );
    if (pin == null || !mounted) return;

    await PanicPinService.instance.setPin(pin);
    if (!mounted) return;
    _showSnack(context.l10n.panicPinSaved);
    await _refresh();
  }

  Future<void> _changePanicPin() async {
    final current = await showPinPad(
      context: context,
      title: context.l10n.currentPanicPin,
      validatePin: (pin) async {
        if (!await PanicPinService.instance.verify(pin)) {
          return context.l10n.incorrectPanicPin;
        }
        return null;
      },
    );
    if (current == null || !mounted) return;

    final pin = await showPinSetupPad(
      context: context,
      title: context.l10n.newPanicPin,
      confirmTitle: context.l10n.confirmNewPanicPin,
      validatePin: _validateNewPanicPin,
    );
    if (pin == null || !mounted) return;

    await PanicPinService.instance.setPin(pin);
    if (!mounted) return;
    _showSnack(context.l10n.panicPinUpdated);
    await _refresh();
  }

  Future<void> _removePanicPin() async {
    final current = await showPinPad(
      context: context,
      title: context.l10n.enterPanicPinToRemove,
      validatePin: (pin) async {
        if (!await PanicPinService.instance.verify(pin)) {
          return context.l10n.incorrectPanicPin;
        }
        return null;
      },
    );
    if (current == null || !mounted) return;

    await PanicPinService.instance.clear();
    if (!mounted) return;
    _showSnack(context.l10n.panicPinRemoved);
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
                    title: action.localizedLabel(context.l10n),
                    subtitle: action.localizedDescription(context.l10n),
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
      title: context.l10n.panicMode,
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
                      context.l10n.panicPinExplanationBody,
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
                  title: _configured
                      ? context.l10n.panicPinIsSet
                      : context.l10n.panicPinNotSet,
                  subtitle: _configured
                      ? context.l10n.secondaryPinIsActive
                      : context.l10n.setPanicPinToEnablePanicMode,
                ),
                const PrysmDivider(),
                PrysmListRow(
                  leading: const Icon(PrysmIcons.emergencyOutlined),
                  title: context.l10n.whenPanicPinIsUsed,
                  subtitle: _action.localizedDescription(context.l10n),
                  trailing: const Icon(PrysmIcons.chevronRight),
                  onTap: _pickAction,
                ),
                const PrysmDivider(),
                if (!_configured)
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.addModeratorOutlined),
                    title: context.l10n.setPanicPin,
                    onTap: _setPanicPin,
                  )
                else ...[
                  PrysmListRow(
                    leading: const Icon(PrysmIcons.pin),
                    title: context.l10n.changePanicPin,
                    onTap: _changePanicPin,
                  ),
                  PrysmListRow(
                    leading: Icon(PrysmIcons.deleteOutline, color: tokens.danger),
                    titleWidget: Text(
                      context.l10n.removePanicPin,
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
