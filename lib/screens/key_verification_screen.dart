import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/crypto/qr_payload.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/services/contact_verification_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class KeyVerificationScreen extends StatefulWidget {
  final Contact peer;
  final KeyManager keyManager;
  final VoidCallback? onVerificationChanged;

  const KeyVerificationScreen({
    required this.peer,
    required this.keyManager,
    this.onVerificationChanged,
    super.key,
  });

  @override
  State<KeyVerificationScreen> createState() => _KeyVerificationScreenState();
}

class _KeyVerificationScreenState extends State<KeyVerificationScreen> {
  final _service = ContactVerificationService.instance;
  late Contact _peer;

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
    _refreshPeerFromDb();
  }

  Future<void> _refreshPeerFromDb() async {
    final row = await DBHelper.getUserById(_peer.id);
    if (!mounted || row == null) return;
    setState(() {
      _peer = Contact.fromMap(row).copyWith(
        lastMessageTimestamp: _peer.lastMessageTimestamp,
      );
    });
  }

  String? get _fingerprint => _service.fingerprintFor(_peer);

  VerificationStatus get _status => _service.statusFor(_peer);

  Future<void> _markVerified(String fingerprint) async {
    await _service.markVerified(_peer.id, fingerprint);
    widget.onVerificationChanged?.call();
    await _refreshPeerFromDb();
    if (!mounted) return;
    showPrysmToast(context, context.l10n.identityVerified);
    Navigator.of(context).pop(_peer);
  }

  Future<void> _scanToVerify() async {
    if (!QrPlatform.isScanSupported) {
      await showPrysmDialog<void>(
        context: context,
        title: context.l10n.scanNotAvailable,
        content: const Text(
          'QR scanning is only supported on mobile devices. '
          'Compare the fingerprint manually and use "Mark as verified".',
        ),
        confirmLabel: 'OK',
        onConfirm: () => Navigator.of(context).pop(),
      );
      return;
    }

    final scanned = await Navigator.push<String>(
      context,
      PrysmPageRoute(page: const QrScannerScreen()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) return;

    final payload = QrPayload.tryParse(scanned);
    if (payload == null) {
      await showPrysmDialog<void>(
        context: context,
        title: context.l10n.invalidQrCode,
        content: Text(context.l10n.thisQrCodeIsNotAValidPrysm),
        confirmLabel: 'OK',
        onConfirm: () => Navigator.of(context).pop(),
      );
      return;
    }

    if (_service.qrMatchesContact(payload, _peer)) {
      await _markVerified(payload.fingerprint);
      return;
    }

    await showPrysmDialog<void>(
      context: context,
      title: context.l10n.verificationFailed,
      content: const Text(
        'The scanned QR code does not match this contact\'s identity. '
        'This may indicate impersonation.',
      ),
      confirmLabel: 'OK',
      onConfirm: () => Navigator.of(context).pop(),
    );
  }

  Future<void> _confirmManualVerify() async {
    final fingerprint = _fingerprint;
    if (fingerprint == null) return;

    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: context.l10n.markAsVerified,
      content: const Text(
        'Only mark this contact as verified if you compared their '
        'fingerprint in person or over a trusted channel.',
      ),
      confirmLabel: 'Mark verified',
    );
    if (confirmed != true || !mounted) return;
    await _markVerified(fingerprint);
  }

  Future<void> _removeVerification() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: context.l10n.removeVerification,
      content: const Text(
        'This contact will no longer be marked as verified.',
      ),
      confirmLabel: 'Remove',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;

    await _service.clearVerification(_peer.id);
    widget.onVerificationChanged?.call();
    await _refreshPeerFromDb();
    if (!mounted) return;
    showPrysmToast(context, context.l10n.verificationRemoved);
  }

  void _copyFingerprint() {
    final fingerprint = _fingerprint;
    if (fingerprint == null) return;
    Clipboard.setData(ClipboardData(text: fingerprint));
    showPrysmToast(context, context.l10n.fingerprintCopied);
  }

  Color _statusColor(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    switch (_status) {
      case VerificationStatus.verified:
        return const Color(0xFF4CAF50);
      case VerificationStatus.keyChanged:
        return const Color(0xFFFF9800);
      case VerificationStatus.unverified:
        return tokens.textMuted;
    }
  }

  IconData _statusIcon() {
    switch (_status) {
      case VerificationStatus.verified:
        return PrysmIcons.checkCircle;
      case VerificationStatus.keyChanged:
        return PrysmIcons.warning;
      case VerificationStatus.unverified:
        return PrysmIcons.fingerprint;
    }
  }

  String _statusMessage() {
    switch (_status) {
      case VerificationStatus.verified:
        return context.l10n.verified;
      case VerificationStatus.keyChanged:
        return context.l10n.keyChangedReVerify;
      case VerificationStatus.unverified:
        return context.l10n.notVerified;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final fingerprint = _fingerprint;
    final encodedId = encodeOnionToBase58(_peer.id);
    final qrData = fingerprint != null
        ? QrPayload(onion: encodedId, fingerprint: fingerprint).encode()
        : encodedId;

    return PrysmPage(
      title: context.l10n.identityVerification,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: () => Navigator.of(context).pop(_peer),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF000000).withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  ContactAvatar(
                    name: _peer.displayName,
                    radius: 48,
                    avatarBase64: _peer.avatarBase64,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _peer.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_statusIcon(), size: 18, color: _statusColor(context)),
                      const SizedBox(width: 8),
                      Text(
                        _statusMessage(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: _statusColor(context),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (fingerprint != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Fingerprint',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _copyFingerprint,
                      child: Text(
                        _service.formatFingerprint(fingerprint),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap to copy',
                      style: TextStyle(fontSize: 12, color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Their QR code',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ask your contact to show this code, or scan theirs to verify.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    PrysmIdQrCode(data: qrData, size: 180),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              PrysmButton(
                label: context.l10n.scanQrCode,
                onPressed: _scanToVerify,
              ),
              const SizedBox(height: 12),
              if (_status != VerificationStatus.verified)
                PrysmButton(
                  label: context.l10n.markAsVerified,
                  variant: PrysmButtonVariant.secondary,
                  onPressed: _confirmManualVerify,
                ),
              if (_status == VerificationStatus.verified) ...[
                const SizedBox(height: 12),
                PrysmButton(
                  label: context.l10n.removeVerification,
                  variant: PrysmButtonVariant.danger,
                  onPressed: _removeVerification,
                ),
              ],
            ] else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'No identity key is stored for this contact yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tokens.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
