import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/services/relay_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/transport/relay_client.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_chip.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';
import 'package:prysm/util/format_file_size.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/util/tor_delivery.dart';

/// Relay pairing, status and mailbox management.
///
/// Three states, all reachable from one [RelayState]:
/// (a) not paired — explainer plus the pairing flow with a manifest preview
/// the user must read before accepting;
/// (b) paired — usage, pickup, per-contact mailboxes with revoke, unpair;
/// (c) error — every [RelayError] is mapped to a sentence, never a trace.
class RelaySettingsScreen extends StatefulWidget {
  final VoidCallback onClose;

  /// Test seam: when set, the screen renders this state instead of
  /// subscribing to [RelayService]. No service calls are made on init.
  @visibleForTesting
  final RelayState? stateOverride;

  /// Test seam: pre-populates the manifest preview of the pairing flow.
  @visibleForTesting
  final RelayPairingPreview? previewOverride;

  /// Action seams. Each defaults to the matching [RelayService] call.
  @visibleForTesting
  final Future<RelayPairingPreview> Function(String relayOnion)? fetchManifestFn;
  @visibleForTesting
  final Future<void> Function({
    required String relayOnion,
    required String token,
  })? pairFn;
  @visibleForTesting
  final Future<void> Function()? unpairFn;
  @visibleForTesting
  final Future<void> Function()? refreshStatusFn;
  @visibleForTesting
  final Future<void> Function(String deposit)? revokeMailboxFn;
  @visibleForTesting
  final Future<Map<String, String>> Function()? mailboxLabelsFn;
  @visibleForTesting
  final Future<int> Function()? pickupNowFn;
  @visibleForTesting
  final Future<void> Function(bool value)? setEnabledFn;

  const RelaySettingsScreen({
    required this.onClose,
    this.stateOverride,
    this.previewOverride,
    this.fetchManifestFn,
    this.pairFn,
    this.unpairFn,
    this.refreshStatusFn,
    this.revokeMailboxFn,
    this.mailboxLabelsFn,
    this.pickupNowFn,
    this.setEnabledFn,
    super.key,
  });

  @override
  State<RelaySettingsScreen> createState() => _RelaySettingsScreenState();
}

class _RelaySettingsScreenState extends State<RelaySettingsScreen> {
  late final TextEditingController _onionController;
  late final TextEditingController _tokenController;

  RelayPairingPreview? _preview;
  bool _fetching = false;
  // Second attempt after a cold-start timeout, with a longer budget.
  bool _retrying = false;
  // Fingerprint carried by the pairing link, if one was applied. Shown next
  // to the fetched manifest and blocks pairing on mismatch. A hand edit of
  // the address field clears it: the expectation came from the link.
  String? _expectedFingerprint;
  // True while the form is filled programmatically, so the address
  // `onChanged` does not mistake it for a hand edit.
  bool _applyingLink = false;
  bool _pairing = false;
  bool _pickingUp = false;
  bool _loadingStatus = false;
  String? _revokingDeposit;
  String? _errorText;
  Map<String, String> _mailboxLabels = const {};

  static const Duration _fetchRetryTimeout = Duration(seconds: 60);

  bool get _live => widget.stateOverride == null;

  @override
  void initState() {
    super.initState();
    _onionController = TextEditingController();
    _tokenController = TextEditingController();
    _preview = widget.previewOverride;
    if (_live && RelayService.instance.current.isPaired) {
      // After the first frame, never inside it: the refresh reads `context`
      // for its error strings and calls `setState`, and both are illegal
      // while `initState` is still running — the whole refresh used to die
      // with a zone error, leaving the mailbox list empty for good.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_onRefreshStatus());
      });
    }
  }

  @override
  void dispose() {
    _onionController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  // ==================== service seam ====================

  Future<RelayPairingPreview> _fetchManifest(
    String relayOnion, {
    Duration? timeout,
  }) {
    final fn = widget.fetchManifestFn;
    // The test seam takes the onion only; the timeout only steers the live
    // service call below.
    if (fn != null) return fn(relayOnion);
    return RelayService.instance.fetchManifest(
      relayOnion,
      timeout: timeout ?? RelayClient.defaultTimeout,
    );
  }

  Future<void> _pair({required String relayOnion, required String token}) {
    final fn = widget.pairFn;
    if (fn != null) return fn(relayOnion: relayOnion, token: token);
    return RelayService.instance.pair(relayOnion: relayOnion, token: token);
  }

  Future<void> _unpair() {
    final fn = widget.unpairFn;
    if (fn != null) return fn();
    return RelayService.instance.unpair();
  }

  Future<void> _refreshStatus() {
    final fn = widget.refreshStatusFn;
    if (fn != null) return fn();
    return RelayService.instance.refreshStatus();
  }

  Future<void> _revokeMailbox(String deposit) {
    final fn = widget.revokeMailboxFn;
    if (fn != null) return fn(deposit);
    return RelayService.instance.revokeMailbox(deposit);
  }

  Future<int> _pickupNow() {
    final fn = widget.pickupNowFn;
    if (fn != null) return fn();
    return RelayService.instance.pickupNow();
  }

  Future<void> _setEnabled(bool value) {
    final fn = widget.setEnabledFn;
    if (fn != null) return fn(value);
    return RelayService.instance.setEnabled(value);
  }

  /// Deposit address -> contact onion, resolved locally. The relay never
  /// learns this mapping, so it is what lets a row show a contact instead
  /// of raw hex.
  Future<void> _loadMailboxLabels() async {
    try {
      final labels =
          await (widget.mailboxLabelsFn?.call() ??
              RelayService.instance.mailboxLabels());
      if (!mounted) return;
      setState(() => _mailboxLabels = labels);
    } catch (_) {
      // Labels are a nicety; rows fall back to the truncated deposit.
    }
  }

  // ==================== actions ====================

  Future<void> _onFetchManifest() async {
    final l10n = context.l10n;
    final onion = _onionController.text.trim();
    if (onion.isEmpty || _fetching) return;
    setState(() {
      _fetching = true;
      _retrying = false;
      _errorText = null;
    });
    try {
      final preview = await _fetchWithColdStartRetry(onion);
      if (!mounted) return;
      setState(() => _preview = preview);
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    } finally {
      if (mounted) {
        setState(() {
          _fetching = false;
          _retrying = false;
        });
      }
    }
  }

  /// One automatic second attempt with a 60 s budget when the first fails on
  /// the transport: the first contact with a fresh relay onion can outlast
  /// the default 30 s timeout while its descriptor propagates (measured
  /// 39.8 s), and that must read as progress, not a mute error.
  Future<RelayPairingPreview> _fetchWithColdStartRetry(String onion) async {
    try {
      return await _fetchManifest(onion);
    } catch (e) {
      if (!mounted || !_isTransportRetryable(e)) rethrow;
      setState(() => _retrying = true);
      return _fetchManifest(onion, timeout: _fetchRetryTimeout);
    }
  }

  /// Transport failure, not the relay answering: a [RelayError] is the relay
  /// talking, and a longer timeout would not change its mind.
  bool _isTransportRetryable(Object error) {
    if (error is RelayError) return false;
    return TorDelivery.isRetryableError(error);
  }

  /// Fills the form from a parsed pairing link, remembers its fingerprint,
  /// and starts reading the relay info on its own.
  void _applyPairingLink(RelayPairingLink link) {
    _applyingLink = true;
    try {
      _onionController.text = link.onion;
      _tokenController.text = link.token;
    } finally {
      _applyingLink = false;
    }
    setState(() {
      _expectedFingerprint = link.fingerprint;
      _preview = null;
      _errorText = null;
    });
    showPrysmToast(context, context.l10n.relayLinkPasted);
    unawaited(_onFetchManifest());
  }

  /// Parses pasted, typed or scanned text as a pairing link. Anything that
  /// does not parse is a banner, never a trace.
  void _applyRawPairingLink(String raw) {
    try {
      _applyPairingLink(RelayPairingLink.parse(raw));
    } on RelayError {
      setState(() => _errorText = context.l10n.relayLinkInvalid);
    }
  }

  void _onAddressChanged(String value) {
    // Programmatic fill from a link, not a hand edit: the fingerprint stays.
    if (_applyingLink) {
      setState(() {});
      return;
    }
    if (RelayPairingLink.looksLike(value)) {
      _applyRawPairingLink(value);
      return;
    }
    // A hand edit invalidates whatever link the expectation came from.
    if (_expectedFingerprint != null) {
      setState(() => _expectedFingerprint = null);
    } else {
      setState(() {});
    }
  }

  Future<void> _onPasteLink() async {
    final String? text;
    try {
      text = (await Clipboard.getData('text/plain'))?.text;
    } catch (_) {
      // Clipboard is unavailable (e.g. some desktop setups); the form is
      // still there to fill by hand, so stay quiet.
      return;
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() => _errorText = context.l10n.relayLinkInvalid);
      return;
    }
    _applyRawPairingLink(text);
  }

  /// Camera scanning lives behind [QrPlatform.isScanSupported]: on desktop
  /// the button is not shown at all, and the link is text to paste.
  Future<void> _onScanLink() async {
    final scanned = await Navigator.push<String>(
      context,
      PrysmPageRoute(page: const QrScannerScreen()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) return;
    _applyRawPairingLink(scanned);
  }

  /// Null when no link set the expectation: nothing to check against.
  bool _fingerprintMatches(RelayPairingPreview preview) {
    final expected = _expectedFingerprint;
    return expected == null || preview.manifest.relayFingerprint == expected;
  }

  Future<void> _onPair() async {
    final l10n = context.l10n;
    final preview = _preview;
    if (preview == null ||
        !preview.signatureValid ||
        !_fingerprintMatches(preview) ||
        _pairing) {
      return;
    }
    setState(() {
      _pairing = true;
      _errorText = null;
    });
    try {
      await _pair(
        relayOnion: preview.relayOnion,
        token: _tokenController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _preview = null);
      showPrysmToast(context, l10n.relayPairedOk);
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<void> _onRefreshStatus() async {
    final l10n = context.l10n;
    if (_loadingStatus) return;
    setState(() {
      _loadingStatus = true;
      _errorText = null;
    });
    try {
      await _refreshStatus();
      await _loadMailboxLabels();
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    } finally {
      if (mounted) setState(() => _loadingStatus = false);
    }
  }

  Future<void> _onPickupNow() async {
    final l10n = context.l10n;
    if (_pickingUp) return;
    setState(() {
      _pickingUp = true;
      _errorText = null;
    });
    try {
      final delivered = await _pickupNow();
      if (!mounted) return;
      showPrysmToast(context, l10n.relayLastPickupDelivered(delivered));
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    } finally {
      if (mounted) setState(() => _pickingUp = false);
    }
  }

  Future<void> _onToggleEnabled(bool value) async {
    final l10n = context.l10n;
    setState(() => _errorText = null);
    try {
      await _setEnabled(value);
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    }
  }

  Future<void> _onRevokeMailbox(RelayMailboxInfo mailbox) async {
    final l10n = context.l10n;
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: l10n.relayRevokeTitle,
      content: Text(l10n.relayRevokeBody),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.relayRevoke,
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _revokingDeposit = mailbox.deposit;
      _errorText = null;
    });
    try {
      await _revokeMailbox(mailbox.deposit);
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    } finally {
      if (mounted) setState(() => _revokingDeposit = null);
    }
  }

  Future<void> _onUnpair() async {
    final l10n = context.l10n;
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: l10n.relayUnpairTitle,
      content: Text(l10n.relayUnpairBody),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.relayUnpairConfirm,
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _errorText = null);
    try {
      await _unpair();
      if (!mounted) return;
      showPrysmToast(context, l10n.relayUnpaired);
    } on RelayError catch (e) {
      if (!mounted) return;
      setState(() => _errorText = _relayErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = l10n.relayErrorGeneric('$e'));
    }
  }

  void _copyOnion(String onion) {
    try {
      Clipboard.setData(ClipboardData(text: onion));
      if (mounted) showPrysmToast(context, context.l10n.relayAddressCopied);
    } catch (_) {
      // Clipboard is unavailable (e.g. some desktop setups); the full
      // address is still visible in the pairing fields, so stay quiet.
    }
  }

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    final override = widget.stateOverride;
    return PrysmPage(
      title: context.l10n.relayTitle,
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: override != null
              ? _buildBody(context, override)
              : ValueListenableBuilder<RelayState>(
                  valueListenable: RelayService.instance.state,
                  builder: (context, state, _) => _buildBody(context, state),
                ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, RelayState state) {
    final style = context.prysmStyle;
    final l10n = context.l10n;
    final persistentError = state.lastError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorText != null) ...[
          _ErrorBanner(text: _errorText!),
          const SizedBox(height: 12),
        ] else if (persistentError != null && persistentError.isNotEmpty) ...[
          _ErrorBanner(text: _relayErrorCodeText(l10n, persistentError)),
          const SizedBox(height: 12),
        ],
        if (state.isPaired && state.contract != null)
          _buildPaired(context, state)
        else
          _buildPairing(context, state),
        const SizedBox(height: 30),
        Text(l10n.relayLimitsNote, style: style.captionStyle),
      ],
    );
  }

  // ==================== (a) not paired ====================

  Widget _buildPairing(BuildContext context, RelayState state) {
    final style = context.prysmStyle;
    final l10n = context.l10n;
    final preview = _preview;
    final canFetch =
        !_fetching && _onionController.text.trim().isNotEmpty && !state.isPaired;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.relayWhatIsIt, style: style.bodyStyle),
        const SizedBox(height: 8),
        Text(l10n.relayWhatItSees, style: style.captionStyle),
        const SizedBox(height: 20),
        Text(l10n.relayTitle, style: style.headlineStyle),
        const SizedBox(height: 12),
        PrysmSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(PrysmTokens.spacing16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PrysmTextField(
                    controller: _onionController,
                    labelText: l10n.relayOnionLabel,
                    hintText: l10n.relayOnionHint,
                    onChanged: _onAddressChanged,
                  ),
                  const SizedBox(height: 12),
                  PrysmTextField(
                    controller: _tokenController,
                    labelText: l10n.relayTokenLabel,
                    hintText: l10n.relayTokenHint,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  PrysmButton(
                    key: const ValueKey('relayPasteLinkButton'),
                    label: l10n.relayPasteLink,
                    variant: PrysmButtonVariant.secondary,
                    onPressed: _fetching ? null : _onPasteLink,
                  ),
                  if (QrPlatform.isScanSupported) ...[
                    const SizedBox(height: 12),
                    PrysmButton(
                      key: const ValueKey('relayScanLinkButton'),
                      label: l10n.relayScanLink,
                      variant: PrysmButtonVariant.secondary,
                      onPressed: _fetching ? null : _onScanLink,
                    ),
                  ],
                  const SizedBox(height: 12),
                  PrysmButton(
                    key: const ValueKey('relayFetchButton'),
                    label: _fetching ? l10n.relayFetching : l10n.relayFetchManifest,
                    onPressed: canFetch ? _onFetchManifest : null,
                  ),
                  if (_fetching) ...[
                    const SizedBox(height: 12),
                    const Center(child: PrysmProgressIndicator()),
                    if (_retrying) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.relayFetchRetrying,
                        style: style.captionStyle,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
        if (preview != null) ...[
          const SizedBox(height: 20),
          _ManifestCard(
            preview: preview,
            pairing: _pairing,
            onPair: _onPair,
            expectedFingerprint: _expectedFingerprint,
          ),
        ],
      ],
    );
  }

  // ==================== (b) paired ====================

  Widget _buildPaired(BuildContext context, RelayState state) {
    final style = context.prysmStyle;
    final l10n = context.l10n;
    final contract = state.contract!;
    final usage = state.usage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrysmSection(
          children: [
            PrysmListRow(
              leading: const Icon(PrysmIcons.cloudOutlined),
              titleWidget: Text(
                _truncateOnion(contract.relayOnion),
                style: style.monoStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: l10n.relayOnionLabel,
              trailing: PrysmIconButton(
                icon: PrysmIcons.copy,
                onPressed: () => _copyOnion(contract.relayOnion),
              ),
            ),
            PrysmSwitchRow(
              title: l10n.relayEnabled,
              subtitle: l10n.relayEnabledSubtitle,
              value: state.enabled,
              onChanged: _onToggleEnabled,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(l10n.relayUsage, style: style.headlineStyle),
        const SizedBox(height: 12),
        PrysmSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(PrysmTokens.spacing16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loadingStatus) ...[
                    const Center(child: PrysmProgressIndicator()),
                    const SizedBox(height: 8),
                    Text(
                      l10n.relayLoadingStatus,
                      style: style.captionStyle,
                      textAlign: TextAlign.center,
                    ),
                  ] else if (usage != null) ...[
                    Text(
                      l10n.relayUsageSummary(
                        usage.items,
                        formatFileSize(usage.bytes),
                      ),
                      style: style.bodyStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      usage.oldestExpiresAt != null
                          ? l10n.relayNextExpiry(
                              _formatDate(usage.oldestExpiresAt!),
                            )
                          : l10n.relayNoStoredMessages,
                      style: style.captionStyle,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${l10n.relayLastPickup}: ${_relativePickup(l10n, state.lastPickupAt)}'
                    ' · ${l10n.relayLastPickupDelivered(state.lastPickupDelivered)}',
                    style: style.captionStyle,
                  ),
                  const SizedBox(height: 12),
                  PrysmButton(
                    key: const ValueKey('relayPickupButton'),
                    label: _pickingUp ? l10n.relayPickingUp : l10n.relayPickupNow,
                    onPressed: _pickingUp ? null : _onPickupNow,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(l10n.relayContractLimits, style: style.headlineStyle),
        const SizedBox(height: 12),
        _LimitsSection(limits: contract.limits),
        const SizedBox(height: 20),
        Text(l10n.relayMailboxes, style: style.headlineStyle),
        const SizedBox(height: 12),
        if (state.mailboxes.isEmpty)
          Text(l10n.relayMailboxEmpty, style: style.captionStyle)
        else
          PrysmSection(
            children: [
              for (final mailbox in state.mailboxes)
                _MailboxRow(
                  mailbox: mailbox,
                  contact: _mailboxLabels[mailbox.deposit],
                  busy: _revokingDeposit == mailbox.deposit,
                  onRevoke: () => _onRevokeMailbox(mailbox),
                ),
            ],
          ),
        const SizedBox(height: 20),
        PrysmButton(
          key: const ValueKey('relayUnpairButton'),
          label: l10n.relayUnpair,
          variant: PrysmButtonVariant.danger,
          onPressed: _onUnpair,
        ),
      ],
    );
  }
}

// ==================== manifest preview ====================

class _ManifestCard extends StatelessWidget {
  final RelayPairingPreview preview;
  final bool pairing;
  final VoidCallback onPair;

  /// Fingerprint carried by the pairing link, if one was applied. A mismatch
  /// blocks pairing the same way a bad signature does.
  final String? expectedFingerprint;

  const _ManifestCard({
    required this.preview,
    required this.pairing,
    required this.onPair,
    this.expectedFingerprint,
  });

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final l10n = context.l10n;
    final manifest = preview.manifest;
    final valid = preview.signatureValid;
    final expected = expectedFingerprint;
    final fingerprintOk =
        expected == null || manifest.relayFingerprint == expected;
    final accepted = valid && fingerprintOk;
    return Container(
      padding: const EdgeInsets.all(PrysmTokens.spacing16),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
        border: accepted ? null : Border.all(color: tokens.danger, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Labelled, because this is the one value the user is asked to
          // compare out of band: a bare hex string says nothing. Stacked
          // rather than beside the chip: label plus 17-char fingerprint plus
          // chip does not fit a narrow screen.
          _FactRow(
            label: l10n.relayFingerprint,
            value: _truncateFingerprint(manifest.relayFingerprint),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: PrysmChip(
              label: manifest.tenancy == RelayTenancy.private
                  ? l10n.relayTenancyPrivate
                  : l10n.relayTenancyPublic,
              selected: true,
              onSelected: (_) {},
            ),
          ),
          const SizedBox(height: 12),
          _FactRow(
            label: l10n.relayAdmission,
            value: switch (manifest.admission) {
              RelayAdmission.open => l10n.relayAdmissionOpen,
              RelayAdmission.invite => l10n.relayAdmissionInvite,
              RelayAdmission.closed => l10n.relayAdmissionClosed,
            },
          ),
          _FactRow(
            label: l10n.relayMaxMessageSize,
            value: formatFileSize(manifest.limits.maxItemBytes),
          ),
          _FactRow(
            label: l10n.relayRetention,
            value: l10n.relayRetentionDays(
              (manifest.limits.itemTtlSeconds / 86400).round(),
            ),
          ),
          _FactRow(
            label: l10n.relayMaxPerContact,
            value: '${manifest.limits.maxMailboxItems}',
          ),
          _FactRow(
            label: l10n.relayMaxStorage,
            value: formatFileSize(manifest.limits.maxTenantBytes),
          ),
          if (manifest.terms.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(l10n.relayTerms, style: style.headlineStyle),
            const SizedBox(height: 4),
            Text(manifest.terms, style: style.bodyStyle),
          ],
          if (!valid) ...[
            const SizedBox(height: 12),
            Text(
              l10n.relayBadSignature,
              style: style.bodyStyle.copyWith(color: tokens.danger),
            ),
          ],
          if (expected != null) ...[
            const SizedBox(height: 12),
            Text(
              fingerprintOk
                  ? l10n.relayLinkFingerprintMatch
                  : l10n.relayLinkFingerprintMismatch,
              style: style.bodyStyle.copyWith(
                color: fingerprintOk ? tokens.textPrimary : tokens.danger,
              ),
            ),
          ],
          const SizedBox(height: 12),
          PrysmButton(
            key: const ValueKey('relayAcceptButton'),
            label: pairing ? l10n.relayPairing : l10n.relayPair,
            onPressed: accepted && !pairing ? onPair : null,
          ),
        ],
      ),
    );
  }
}

// ==================== small pieces ====================

class _LimitsSection extends StatelessWidget {
  final RelayLimits limits;

  const _LimitsSection({required this.limits});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PrysmSection(
      children: [
        Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FactRow(
                label: l10n.relayMaxMessageSize,
                value: formatFileSize(limits.maxItemBytes),
              ),
              _FactRow(
                label: l10n.relayRetention,
                value: l10n.relayRetentionDays(
                  (limits.itemTtlSeconds / 86400).round(),
                ),
              ),
              _FactRow(
                label: l10n.relayMaxPerContact,
                value: '${limits.maxMailboxItems}',
              ),
              _FactRow(
                label: l10n.relayMaxStorage,
                value: formatFileSize(limits.maxTenantBytes),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FactRow extends StatelessWidget {
  final String label;
  final String value;

  const _FactRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style.captionStyle)),
          const SizedBox(width: 12),
          Text(value, style: style.bodyStyle),
        ],
      ),
    );
  }
}

class _MailboxRow extends StatelessWidget {
  final RelayMailboxInfo mailbox;
  final String? contact;
  final bool busy;
  final VoidCallback onRevoke;

  const _MailboxRow({
    required this.mailbox,
    this.contact,
    required this.busy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final l10n = context.l10n;
    final hasLabel = mailbox.label != null && mailbox.label!.isNotEmpty;
    final title =
        hasLabel ? mailbox.label! : (contact ?? _truncateDeposit(mailbox.deposit));
    return PrysmListRow(
      leading: Icon(
        mailbox.enabled ? PrysmIcons.cloudOutlined : PrysmIcons.offline,
      ),
      titleWidget: Text(
        title,
        style: hasLabel ? style.titleStyle : style.monoStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle:
          '${l10n.relayMailboxItems(mailbox.items)} · ${formatFileSize(mailbox.bytes)}',
      trailing: busy
          ? const PrysmProgressIndicator()
          : PrysmIconButton(
              key: ValueKey('relayRevoke-${mailbox.deposit}'),
              icon: PrysmIcons.deleteOutlined,
              onPressed: onRevoke,
            ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String text;

  const _ErrorBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(PrysmTokens.spacing12),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
        border: Border.all(color: tokens.danger),
      ),
      child: Text(
        text,
        style: style.bodyStyle.copyWith(color: tokens.danger),
      ),
    );
  }
}

// ==================== text helpers ====================

String _truncateFingerprint(String fingerprint) {
  if (fingerprint.length <= 17) return fingerprint;
  return '${fingerprint.substring(0, 8)}…${fingerprint.substring(fingerprint.length - 8)}';
}

String _truncateOnion(String onion) {
  if (onion.length <= 22) return onion;
  return '${onion.substring(0, 12)}…${onion.substring(onion.length - 8)}';
}

String _truncateDeposit(String deposit) {
  if (deposit.length <= 17) return deposit;
  return '${deposit.substring(0, 10)}…${deposit.substring(deposit.length - 6)}';
}

String _formatDate(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

String _relativePickup(AppLocalizations l10n, int? at) {
  if (at == null) return l10n.relayLastPickupNever;
  final diffMs = DateTime.now().millisecondsSinceEpoch - at;
  if (diffMs < 60000) return l10n.relayLastPickupJustNow;
  final minutes = diffMs ~/ 60000;
  if (minutes < 60) return l10n.relayLastPickupMinutes(minutes);
  final hours = minutes ~/ 60;
  if (hours < 24) return l10n.relayLastPickupHours(hours);
  return l10n.relayLastPickupDays(hours ~/ 24);
}

/// Maps a [RelayError] to a human sentence plus whether retrying is worth it.
String _relayErrorText(AppLocalizations l10n, RelayError error) {
  return '${_relayErrorCodeText(l10n, error.code)} '
      '${error.retryable ? l10n.relayErrorRetryable : l10n.relayErrorNoRetry}';
}

/// Maps a raw error code (from [RelayError] or persistent `lastError`) to a
/// sentence. Unknown codes fall back to a generic sentence plus the raw code.
String _relayErrorCodeText(AppLocalizations l10n, String code) {
  if (code == RelayErrorCode.badToken) return l10n.relayErrorBadToken;
  if (code == RelayErrorCode.admissionClosed) {
    return l10n.relayErrorAdmissionClosed;
  }
  if (code == RelayErrorCode.notPaired) return l10n.relayErrorNotPaired;
  if (code == RelayErrorCode.mailboxFull) return l10n.relayErrorMailboxFull;
  if (code == RelayErrorCode.tenantFull) return l10n.relayErrorTenantFull;
  if (code == RelayErrorCode.rateLimited) return l10n.relayErrorRateLimited;
  if (code == RelayErrorCode.staleRequest) return l10n.relayErrorStaleRequest;
  if (code == RelayErrorCode.badSignature) return l10n.relayErrorBadSignature;
  if (code == RelayErrorCode.internal) return l10n.relayErrorInternal;
  return l10n.relayErrorGeneric(code);
}
