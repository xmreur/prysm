import 'package:flutter/widgets.dart';
import 'package:prysm/crypto/qr_payload.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/qr_platform.dart';

const defaultContactAddErrorMessage =
    'Could not reach peer or fetch their public key. '
    'Make sure they are online and try again.';

typedef ContactAddCallback = Future<bool> Function(
  String onionId,
  String displayName, {
  String? expectedFingerprint,
});

Future<void> showContactAddErrorDialog(
  BuildContext context, {
  String? message,
}) {
  return showPrysmDialog<void>(
    context: context,
    title: 'Could not add contact',
    content: Text(message ?? defaultContactAddErrorMessage),
    confirmLabel: 'OK',
    onConfirm: () => Navigator.of(context).pop(),
  );
}

Widget buildContactAddLoadingRow(PrysmResolvedStyle style) {
  return Row(
    children: [
      const PrysmProgressIndicator(size: 20),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          'Looking up contact on Tor...',
          style: style.bodyStyle,
        ),
      ),
    ],
  );
}

Future<void> showAddContactDialog({
  required BuildContext context,
  String? prefilledId,
  bool decoyMode = false,
  required ContactAddCallback onAdd,
  Future<void> Function()? onScanQr,
}) async {
  String? onionPrefill = prefilledId;
  String? expectedFingerprint;
  if (prefilledId != null) {
    final payload = QrPayload.tryParse(prefilledId);
    if (payload != null) {
      onionPrefill = payload.onion;
      expectedFingerprint = payload.fingerprint;
    }
  }

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x80000000),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Center(
        child: AddContactDialog(
          prefilledId: onionPrefill,
          expectedFingerprint: expectedFingerprint,
          decoyMode: decoyMode,
          onAdd: onAdd,
          onScanQr: onScanQr,
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class AddContactDialog extends StatefulWidget {
  const AddContactDialog({
    required this.onAdd,
    this.prefilledId,
    this.expectedFingerprint,
    this.decoyMode = false,
    this.onScanQr,
    super.key,
  });

  final String? prefilledId;
  final String? expectedFingerprint;
  final bool decoyMode;
  final ContactAddCallback onAdd;
  final Future<void> Function()? onScanQr;

  @override
  State<AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<AddContactDialog> {
  late final TextEditingController _idController;
  late final TextEditingController _nameController;
  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    _idController = TextEditingController(text: widget.prefilledId ?? '');
    _nameController = TextEditingController();
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    String onionId;
    try {
      onionId = decodeBase58ToOnion(_idController.text.trim());
    } catch (_) {
      showPrysmToast(context, 'Enter a valid Base58 Prysm ID');
      return;
    }

    final displayName = _nameController.text.trim();
    if (onionId.isEmpty || onionId == '.onion' || displayName.isEmpty) {
      showPrysmToast(context, 'Enter both ID and display name');
      return;
    }

    setState(() => _isAdding = true);

    if (widget.decoyMode) {
      if (!mounted) return;
      await showContactAddErrorDialog(context);
      if (mounted) setState(() => _isAdding = false);
      return;
    }

    final added = await widget.onAdd(
      onionId,
      displayName,
      expectedFingerprint: widget.expectedFingerprint,
    );

    if (!mounted) return;

    if (!added) {
      await showContactAddErrorDialog(context);
      if (mounted) setState(() => _isAdding = false);
      return;
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;

    return PopScope(
      canPop: !_isAdding,
      child: PrysmDialog(
        title: 'Add contact',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'User ID (Base58 Onion URL)',
                        style: style.captionStyle,
                      ),
                      const SizedBox(height: 6),
                      PrysmTextField(
                        controller: _idController,
                        autofocus: widget.prefilledId == null,
                        hintText: 'eg. 51EsbujFRDJLHJ',
                        enabled: !_isAdding,
                      ),
                    ],
                  ),
                ),
                if (QrPlatform.isScanSupported)
                  Semantics(
                    label: 'Scan QR code',
                    button: true,
                    child: PrysmIconButton(
                      icon: PrysmIcons.qrCodeScanner,
                      tooltip: 'Scan QR code',
                      onPressed: _isAdding ? null : () => widget.onScanQr?.call(),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Display name', style: style.captionStyle),
            const SizedBox(height: 6),
            PrysmTextField(
              controller: _nameController,
              autofocus: widget.prefilledId != null,
              hintText: 'eg. Alice',
              enabled: !_isAdding,
              onSubmitted: _isAdding ? null : (_) => _submit(),
            ),
            if (_isAdding) ...[
              const SizedBox(height: 16),
              buildContactAddLoadingRow(style),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PrysmPressable(
                  enabled: !_isAdding,
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('Cancel', style: style.bodyStyle),
                  ),
                ),
                const SizedBox(width: 8),
                _isAdding
                    ? const SizedBox(
                        width: 72,
                        height: 40,
                        child: Center(
                          child: PrysmProgressIndicator(size: 20),
                        ),
                      )
                    : PrysmButton(
                        label: 'Add',
                        onPressed: _submit,
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
