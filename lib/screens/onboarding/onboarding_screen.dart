import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/screens/widgets/add_contact_dialog.dart';
import 'package:prysm/screens/widgets/backup_flow.dart';
import 'package:prysm/screens/widgets/pin_keypad.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/qr_platform.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_chip.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';

class OnboardingScreen extends StatefulWidget {
  final String onionAddress;
  final bool torReady;
  final bool offlineMode;
  final bool isReplay;
  final bool isInitialSetup;
  final KeyManager? keyManager;
  final int? torBootstrapProgress;
  final VoidCallback onComplete;

  const OnboardingScreen({
    required this.onionAddress,
    required this.torReady,
    required this.onComplete,
    this.offlineMode = false,
    this.isReplay = false,
    this.isInitialSetup = false,
    this.keyManager,
    this.torBootstrapProgress,
    super.key,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  final _settings = SettingsService();
  int _currentPage = 0;

  bool _backupCreated = false;
  bool _contactAdded = false;
  bool _addingContact = false;

  UnlockType _selectedUnlockType = UnlockType.pin;
  bool _unlockSetupComplete = false;
  String _setupPin = '';
  String? _setupPendingPin;
  String? _setupError;
  bool _setupLoading = false;
  final _passphraseController = TextEditingController();
  final _passphraseConfirmController = TextEditingController();
  bool _passphraseObscure = true;

  final _contactIdController = TextEditingController();
  final _contactNameController = TextEditingController();

  int get _stepCount => widget.isInitialSetup ? 7 : 6;

  String get _prysmId {
    if (widget.onionAddress.isEmpty) return '';
    return encodeOnionToBase58(widget.onionAddress);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _contactIdController.dispose();
    _contactNameController.dispose();
    _passphraseController.dispose();
    _passphraseConfirmController.dispose();
    super.dispose();
  }

  Future<void> _finish({bool markComplete = true}) async {
    if (markComplete) {
      await _settings.setOnboardingCompleted(true);
    }
    if (!mounted) return;
    if (widget.isReplay) {
      Navigator.of(context).pop();
    } else {
      widget.onComplete();
    }
  }

  void _skipTour() => _finish();

  bool get _canAdvance {
    if (widget.isInitialSetup && _pageIndexForUnlockSetup == _currentPage) {
      return _unlockSetupComplete;
    }
    return true;
  }

  int get _pageIndexForUnlockSetup => widget.isInitialSetup ? 1 : -1;

  void _nextPage() {
    if (!_canAdvance || _currentPage >= _stepCount - 1) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _previousPage() {
    if (_currentPage <= 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _createBackup() async {
    final created = await showCreateBackupDialog(context);
    if (!mounted || !created) return;
    setState(() => _backupCreated = true);
  }

  Future<void> _addContact() async {
    if (widget.offlineMode) {
      _showSnack('Connect to Tor before adding contacts');
      return;
    }

    String onionId;
    try {
      onionId = decodeBase58ToOnion(_contactIdController.text.trim());
    } catch (_) {
      _showSnack('Enter a valid Base58 Prysm ID');
      return;
    }
    final name = _contactNameController.text.trim();
    if (onionId.isEmpty || onionId == '.onion' || name.isEmpty) {
      _showSnack('Enter both ID and display name');
      return;
    }

    setState(() => _addingContact = true);
    final added = await ContactAddService.instance.addContact(
      onionId: onionId,
      displayName: name,
    );
    if (!mounted) return;
    setState(() => _addingContact = false);

    if (!added) {
      await showContactAddErrorDialog(context);
      return;
    }
    setState(() => _contactAdded = true);
    _showSnack('Contact added');
  }

  void _showSnack(String message) {
    showPrysmToast(context, message);
  }

  void _copyPrysmId() {
    if (_prysmId.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _prysmId));
    _showSnack('Prysm ID copied');
  }

  String _truncateId(String id) {
    if (id.length <= 16) return id;
    return '${id.substring(0, 8)}…${id.substring(id.length - 6)}';
  }

  Future<void> _completeUnlockSetup(String secret) async {
    final km = widget.keyManager;
    if (km == null) return;
    setState(() {
      _setupLoading = true;
      _setupError = null;
    });
    final ok = await km.unlockWithPassphrase(
      secret,
      type: _selectedUnlockType,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _setupLoading = false;
        _setupError = _selectedUnlockType == UnlockType.pin
            ? 'Could not set up PIN. Try again.'
            : 'Could not set up passphrase. Use at least 12 characters.';
        _setupPin = '';
        _setupPendingPin = null;
      });
      return;
    }
    await _settings.setUnlockType(_selectedUnlockType);
    setState(() {
      _setupLoading = false;
      _unlockSetupComplete = true;
      _setupError = null;
    });
    _showSnack('Unlock method saved');
  }

  void _onSetupPinKey(String key) {
    if (_setupLoading || _unlockSetupComplete) return;
    if (key == 'back') {
      if (_setupPin.isNotEmpty) {
        setState(() => _setupPin = _setupPin.substring(0, _setupPin.length - 1));
      } else if (_setupPendingPin != null) {
        setState(() {
          _setupPendingPin = null;
          _setupError = null;
        });
      }
      return;
    }
    if (_setupPin.length < 6) {
      setState(() => _setupPin += key);
    }
    if (_setupPin.length == 6) {
      if (_setupPendingPin == null) {
        setState(() {
          _setupPendingPin = _setupPin;
          _setupPin = '';
        });
        return;
      }
      if (_setupPin != _setupPendingPin) {
        setState(() {
          _setupError = "PINs don't match";
          _setupPin = '';
          _setupPendingPin = null;
        });
        return;
      }
      _completeUnlockSetup(_setupPin);
    }
  }

  Future<void> _submitPassphraseSetup() async {
    final value = _passphraseController.text;
    if (value.length < 12) {
      setState(() => _setupError = 'Passphrase must be at least 12 characters');
      return;
    }
    if (value != _passphraseConfirmController.text) {
      setState(() => _setupError = 'Passphrases do not match');
      return;
    }
    await _completeUnlockSetup(value);
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;

    return PrysmPage(
      title: widget.isInitialSetup
          ? 'Set up Prysm'
          : widget.isReplay
              ? 'Getting started'
              : 'Welcome to Prysm',
      leading: widget.isReplay
          ? PrysmIconButton(
              icon: PrysmIcons.close,
              onPressed: () => Navigator.of(context).pop(),
            )
          : null,
      actions: [
        if (!widget.isReplay && !widget.isInitialSetup)
          PrysmTextButton(label: 'Skip tour', onPressed: _skipTour),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                Text(
                  'Step ${_currentPage + 1} of $_stepCount',
                  style: style.captionStyle.copyWith(
                    color: tokens.textMuted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: List.generate(_stepCount, (i) {
                      final active = i <= _currentPage;
                      return Expanded(
                        child: Container(
                          height: 4,
                          margin:
                              EdgeInsets.only(right: i < _stepCount - 1 ? 4 : 0),
                          decoration: BoxDecoration(
                            color: active
                                ? tokens.accent
                                : tokens.surfaceElevated,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _currentPage = i),
              children: _buildPages(style),
            ),
          ),
          _bottomBar(style),
        ],
      ),
    );
  }

  List<Widget> _buildPages(PrysmResolvedStyle style) {
    if (widget.isInitialSetup) {
      return [
        _welcomeStep(style),
        _unlockSetupStep(style),
        _torStep(style),
        _unlockInfoStep(style),
        _backupStep(style),
        _addContactStep(style),
        _onionIdStep(style),
      ];
    }
    return [
      _welcomeStep(style),
      _torStep(style),
      _unlockInfoStep(style),
      _backupStep(style),
      _addContactStep(style),
      _onionIdStep(style),
    ];
  }

  Widget _bottomBar(PrysmResolvedStyle style) {
    final isLast = _currentPage == _stepCount - 1;
    final isFirst = _currentPage == 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            if (!isFirst)
              PrysmTextButton(label: 'Back', onPressed: _previousPage)
            else
              const SizedBox(width: 64),
            const Spacer(),
            if (isLast)
              PrysmButton(label: 'Get started', onPressed: () => _finish())
            else
              PrysmButton(label: 'Next', onPressed: _canAdvance ? _nextPage : null),
          ],
        ),
      ),
    );
  }

  Widget _stepScaffold({
    required PrysmResolvedStyle style,
    required IconData icon,
    required String title,
    required String body,
    List<String>? bullets,
    Widget? extra,
  }) {
    final tokens = style.tokens;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 40, color: tokens.accent),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: style.headlineStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: style.bodyStyle.copyWith(height: 1.5),
          ),
          if (bullets != null) ...[
            const SizedBox(height: 16),
            ...bullets.map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• ', style: style.bodyStyle),
                    Expanded(child: Text(b, style: style.bodyStyle)),
                  ],
                ),
              ),
            ),
          ],
          if (extra != null) ...[
            const SizedBox(height: 24),
            extra,
          ],
        ],
      ),
    );
  }

  Widget _welcomeStep(PrysmResolvedStyle style) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Image.asset('assets/logo.png', height: 80, width: 80),
          const SizedBox(height: 32),
          Text(
            widget.isInitialSetup ? 'Welcome to Prysm' : 'Welcome to Prysm',
            style: style.headlineStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            widget.isInitialSetup
                ? 'Choose how you unlock Prysm and protect your keys. '
                    'This setup is required before you can use the app.'
                : 'Private messaging over Tor. This short tour covers the '
                    'essentials so you can start chatting confidently.',
            style: style.bodyStyle.copyWith(
              color: style.tokens.textMuted,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (!widget.isReplay && !widget.isInitialSetup)
            PrysmButton(label: 'Skip tour', onPressed: _skipTour),
        ],
      ),
    );
  }

  Widget _unlockSetupStep(PrysmResolvedStyle style) {
    final tokens = style.tokens;
    final pinConfirm = _setupPendingPin != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Choose your unlock method',
            style: style.headlineStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pick one method. You can change it later in Settings.',
            style: style.bodyStyle.copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: PrysmChip(
                  label: '6-digit PIN',
                  selected: _selectedUnlockType == UnlockType.pin,
                  onSelected: (_) {
                    if (_unlockSetupComplete) return;
                    setState(() {
                      _selectedUnlockType = UnlockType.pin;
                      _setupError = null;
                      _setupPin = '';
                      _setupPendingPin = null;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PrysmChip(
                  label: 'Passphrase',
                  selected: _selectedUnlockType == UnlockType.passphrase,
                  onSelected: (_) {
                    if (_unlockSetupComplete) return;
                    setState(() {
                      _selectedUnlockType = UnlockType.passphrase;
                      _setupError = null;
                      _setupPin = '';
                      _setupPendingPin = null;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_unlockSetupComplete)
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(PrysmIcons.checkCircleOutline, color: Color(0xFF4CAF50)),
                    SizedBox(width: 8),
                    Expanded(child: Text('Unlock method configured')),
                  ],
                ),
              ),
            )
          else if (_selectedUnlockType == UnlockType.pin) ...[
            Text(
              pinConfirm ? 'Confirm your PIN' : 'Create your PIN',
              style: style.titleStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_setupLoading)
              const Center(child: PrysmProgressIndicator())
            else
              Center(child: PinDots(filledCount: _setupPin.length)),
            if (_setupError != null) ...[
              const SizedBox(height: 12),
              Text(
                _setupError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.danger),
              ),
            ],
            const SizedBox(height: 24),
            PinKeypad(onKeyPress: _onSetupPinKey),
          ] else ...[
            PrysmTextField(
              controller: _passphraseController,
              labelText: 'Passphrase',
              obscureText: _passphraseObscure,
              enabled: !_setupLoading,
              suffixIcon: PrysmIconButton(
                icon: _passphraseObscure
                    ? PrysmIcons.visibility
                    : PrysmIcons.visibilityOff,
                onPressed: () =>
                    setState(() => _passphraseObscure = !_passphraseObscure),
              ),
            ),
            const SizedBox(height: 12),
            PrysmTextField(
              controller: _passphraseConfirmController,
              labelText: 'Confirm passphrase',
              obscureText: _passphraseObscure,
              enabled: !_setupLoading,
            ),
            if (_setupError != null) ...[
              const SizedBox(height: 12),
              Text(
                _setupError!,
                style: TextStyle(color: tokens.danger),
              ),
            ],
            const SizedBox(height: 16),
            PrysmButton(
              label: 'Save passphrase',
              onPressed: _setupLoading ? null : _submitPassphraseSetup,
            ),
          ],
          if (widget.torBootstrapProgress != null) ...[
            const SizedBox(height: 16),
            Text(
              'Tor: ${widget.torBootstrapProgress}%',
              textAlign: TextAlign.center,
              style: style.captionStyle,
            ),
          ],
        ],
      ),
    );
  }

  Widget _torStep(PrysmResolvedStyle style) {
    final connected = widget.torReady;
    final offline = widget.offlineMode && !connected;
    return _stepScaffold(
      style: style,
      icon: PrysmIcons.shieldOutlined,
      title: 'Built on Tor',
      body:
          'Prysm routes all traffic through the Tor network. Your messages '
          'reach contacts directly — no central server stores your chats.',
      bullets: const [
        'Your onion address is your identity on the network',
        'The Tor status in the app bar shows your connection',
        'Tor must be connected before you can message anyone',
      ],
      extra: DecoratedBox(
        decoration: BoxDecoration(
          color: style.tokens.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected
                      ? const Color(0xFF4CAF50)
                      : offline
                          ? style.tokens.danger
                          : const Color(0xFFFF9800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  connected
                      ? 'Tor is connected'
                      : offline
                          ? 'Offline — connect later to get your Prysm ID'
                          : 'Tor is connecting…',
                  style: style.titleStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unlockInfoStep(PrysmResolvedStyle style) {
    final isPin = _settings.unlockType == UnlockType.pin;
    return _stepScaffold(
      style: style,
      icon: PrysmIcons.lock,
      title: isPin
          ? 'Your PIN protects your keys'
          : 'Your passphrase protects your keys',
      body: isPin
          ? 'Your 6-digit PIN encrypts your private keys on this device — '
              'Prysm never sees or stores it in the cloud.'
          : 'Your passphrase encrypts your private keys on this device — '
              'Prysm never sees or stores it in the cloud.',
      bullets: [
        'There is no "forgot ${isPin ? 'PIN' : 'passphrase'}" recovery',
        'If you lose your ${isPin ? 'PIN' : 'passphrase'}, only a backup can restore your account',
        'Never share your ${isPin ? 'PIN' : 'passphrase'} with anyone',
        'After 5 failed unlock attempts, Prysm locks for 2 hours',
        if (!widget.isReplay)
          'Change unlock method anytime in Settings → Privacy',
      ],
    );
  }

  Widget _backupStep(PrysmResolvedStyle style) {
    return _stepScaffold(
      style: style,
      icon: PrysmIcons.backupOutlined,
      title: 'Back up your account',
      body:
          'A backup saves your chats, contacts, and encrypted keys. Without '
          'one, losing this device or forgetting your unlock code means losing '
          'everything.',
      bullets: const [
        'Backups are password-encrypted files (.prysmbackup)',
        'Store the file somewhere safe outside this device',
        'You can create more backups anytime in Settings → Data',
      ],
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_backupCreated)
            DecoratedBox(
              decoration: BoxDecoration(
                color: style.tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(PrysmIcons.checkCircleOutline, color: Color(0xFF4CAF50)),
                    SizedBox(width: 8),
                    Expanded(child: Text('Backup created')),
                  ],
                ),
              ),
            ),
          if (_backupCreated) const SizedBox(height: 12),
          PrysmButton(
            label: _backupCreated ? 'Create another backup' : 'Create backup now',
            onPressed: _createBackup,
          ),
          if (!widget.isInitialSetup) ...[
            const SizedBox(height: 8),
            PrysmTextButton(label: 'Skip for now', onPressed: _nextPage),
          ],
        ],
      ),
    );
  }

  Widget _addContactStep(PrysmResolvedStyle style) {
    final tokens = style.tokens;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              PrysmIcons.personAddAlt1Outlined,
              size: 40,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Add your first contact',
            style: style.headlineStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.offlineMode
                ? 'Connect to Tor to add contacts. You can skip this step and '
                    'add friends later from the main app.'
                : 'Ask a friend for their Prysm ID (a Base58 code or QR). '
                    'They must be online on Tor for the first connection.',
            style: style.bodyStyle.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          if (_contactAdded)
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(PrysmIcons.checkCircleOutline, color: Color(0xFF4CAF50)),
                    SizedBox(width: 8),
                    Expanded(child: Text('Contact added successfully')),
                  ],
                ),
              ),
            ),
          if (_contactAdded) const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: PrysmTextField(
                  controller: _contactIdController,
                  labelText: 'Prysm ID (Base58)',
                  hintText: 'eg. 51EsbujFRDJLHJ',
                  enabled: !_addingContact,
                ),
              ),
              if (QrPlatform.isScanSupported)
                PrysmIconButton(
                  icon: PrysmIcons.qrCodeScanner,
                  tooltip: 'Scan QR code',
                  onPressed: _addingContact
                      ? null
                      : () async {
                    final scanned = await Navigator.push<String>(
                      context,
                      PrysmPageRoute(page: const QrScannerScreen()),
                    );
                    if (scanned != null && scanned.isNotEmpty) {
                      _contactIdController.text = scanned;
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          PrysmTextField(
            controller: _contactNameController,
            labelText: 'Display name',
            enabled: !_addingContact,
          ),
          const SizedBox(height: 16),
          PrysmButton(
            label: 'Add contact',
            onPressed: widget.offlineMode || _addingContact ? null : _addContact,
          ),
          if (_addingContact) ...[
            const SizedBox(height: 16),
            buildContactAddLoadingRow(style),
          ],
          if (!widget.isInitialSetup) ...[
            const SizedBox(height: 8),
            PrysmTextButton(label: 'Skip for now', onPressed: _nextPage),
          ],
        ],
      ),
    );
  }

  Widget _onionIdStep(PrysmResolvedStyle style) {
    final tokens = style.tokens;
    final hasId = _prysmId.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              PrysmIcons.fingerprintOutlined,
              size: 40,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your Prysm ID',
            style: style.headlineStyle.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This is your unique address on Tor. Friends use it to add you. '
            'It is a Base58 encoding of your .onion hidden service address.',
            style: style.bodyStyle.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          if (hasId) ...[
            Center(
              child: PrysmIdQrCode(data: _prysmId, size: 160),
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _truncateId(_prysmId),
                        style: style.bodyStyle.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    PrysmIconButton(
                      icon: PrysmIcons.copyRounded,
                      tooltip: 'Copy ID',
                      onPressed: _copyPrysmId,
                    ),
                    PrysmIconButton(
                      icon: PrysmIcons.qrCode,
                      tooltip: 'Show full QR',
                      onPressed: () => showPrysmIdQrDialog(context, _prysmId),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Your Prysm ID will appear once Tor finishes connecting.',
                  style: style.bodyStyle,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'Share this ID or QR so others can message you. You can always '
            'find it in your profile or the sidebar.',
            style: style.captionStyle.copyWith(color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}
