import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prysm/screens/widgets/backup_flow.dart';
import 'package:prysm/screens/widgets/prysm_id_qr.dart';
import 'package:prysm/screens/widgets/qr_scanner_screen.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/util/qr_platform.dart';

class OnboardingScreen extends StatefulWidget {
  final String onionAddress;
  final bool torReady;
  final bool isReplay;
  final VoidCallback onComplete;

  const OnboardingScreen({
    required this.onionAddress,
    required this.torReady,
    required this.onComplete,
    this.isReplay = false,
    super.key,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _stepCount = 6;

  final _pageController = PageController();
  final _settings = SettingsService();
  int _currentPage = 0;

  bool _backupCreated = false;
  bool _contactAdded = false;
  bool _addingContact = false;

  final _contactIdController = TextEditingController();
  final _contactNameController = TextEditingController();

  String get _prysmId => encodeOnionToBase58(widget.onionAddress);

  @override
  void dispose() {
    _pageController.dispose();
    _contactIdController.dispose();
    _contactNameController.dispose();
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

  void _nextPage() {
    if (_currentPage >= _stepCount - 1) return;
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
    await showCreateBackupDialog(context);
    if (!mounted) return;
    setState(() => _backupCreated = true);
  }

  Future<void> _addContact() async {
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
      _showSnack(
        'Could not reach peer or fetch their public key. '
        'Make sure they are online and try again.',
      );
      return;
    }
    setState(() => _contactAdded = true);
    _showSnack('Contact added');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copyPrysmId() {
    Clipboard.setData(ClipboardData(text: _prysmId));
    _showSnack('Prysm ID copied');
  }

  String _truncateId(String id) {
    if (id.length <= 16) return id;
    return '${id.substring(0, 8)}…${id.substring(id.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReplay ? 'Getting started' : 'Welcome to Prysm'),
        automaticallyImplyLeading: widget.isReplay,
        leading: widget.isReplay
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        actions: [
          if (!widget.isReplay)
            TextButton(
              onPressed: _skipTour,
              child: const Text('Skip tour'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                Text(
                  'Step ${_currentPage + 1} of $_stepCount',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.hintColor,
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
                          margin: EdgeInsets.only(right: i < _stepCount - 1 ? 4 : 0),
                          decoration: BoxDecoration(
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
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
              children: [
                _welcomeStep(theme),
                _torStep(theme),
                _pinStep(theme),
                _backupStep(theme),
                _addContactStep(theme),
                _onionIdStep(theme),
              ],
            ),
          ),
          _bottomBar(theme),
        ],
      ),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    final isLast = _currentPage == _stepCount - 1;
    final isFirst = _currentPage == 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            if (!isFirst)
              TextButton(
                onPressed: _previousPage,
                child: const Text('Back'),
              )
            else
              const SizedBox(width: 64),
            const Spacer(),
            if (isLast)
              FilledButton(
                onPressed: () => _finish(),
                child: const Text('Get started'),
              )
            else
              FilledButton(
                onPressed: _nextPage,
                child: const Text('Next'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stepScaffold({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String body,
    List<String>? bullets,
    Widget? extra,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 40, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
          if (bullets != null) ...[
            const SizedBox(height: 16),
            ...bullets.map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• ', style: theme.textTheme.bodyLarge),
                    Expanded(child: Text(b, style: theme.textTheme.bodyLarge)),
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

  Widget _welcomeStep(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Image.asset('assets/logo.png', height: 80, width: 80),
          const SizedBox(height: 32),
          Text(
            'Welcome to Prysm',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Private messaging over Tor. This short tour covers the essentials '
            'so you can start chatting confidently.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.hintColor,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (!widget.isReplay)
            OutlinedButton(
              onPressed: _skipTour,
              child: const Text('Skip tour'),
            ),
        ],
      ),
    );
  }

  Widget _torStep(ThemeData theme) {
    final connected = widget.torReady;
    return _stepScaffold(
      theme: theme,
      icon: Icons.shield_outlined,
      title: 'Built on Tor',
      body:
          'Prysm routes all traffic through the Tor network. Your messages '
          'reach contacts directly — no central server stores your chats.',
      bullets: const [
        'Your onion address is your identity on the network',
        'The Tor status in the app bar shows your connection',
        'Tor must be connected before you can message anyone',
      ],
      extra: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected ? Colors.green : Colors.orange,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                connected ? 'Tor is connected' : 'Tor is connecting…',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pinStep(ThemeData theme) {
    return _stepScaffold(
      theme: theme,
      icon: Icons.lock_outline,
      title: 'Your passcode protects your keys',
      body:
          'You just set a 6-digit passcode. It encrypts your private keys on '
          'this device — Prysm never sees or stores it in the cloud.',
      bullets: const [
        'There is no "forgot passcode" recovery',
        'If you lose your passcode, only a backup can restore your account',
        'Never share your passcode with anyone',
      ],
    );
  }

  Widget _backupStep(ThemeData theme) {
    return _stepScaffold(
      theme: theme,
      icon: Icons.backup_outlined,
      title: 'Back up your account',
      body:
          'A backup saves your chats, contacts, and encrypted keys. Without '
          'one, losing this device or forgetting your passcode means losing '
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
            Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.green),
                    SizedBox(width: 8),
                    Expanded(child: Text('Backup created')),
                  ],
                ),
              ),
            ),
          if (_backupCreated) const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _createBackup,
            icon: const Icon(Icons.backup_outlined),
            label: Text(_backupCreated ? 'Create another backup' : 'Create backup now'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _nextPage,
            child: const Text('Skip for now'),
          ),
        ],
      ),
    );
  }

  Widget _addContactStep(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.person_add_alt_1_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Add your first contact',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Ask a friend for their Prysm ID (a Base58 code or QR). '
            'They must be online on Tor for the first connection.',
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          if (_contactAdded)
            Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.green),
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
                child: TextField(
                  controller: _contactIdController,
                  decoration: const InputDecoration(
                    labelText: 'Prysm ID (Base58)',
                    hintText: 'eg. 51EsbujFRDJLHJ',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (QrPlatform.isScanSupported)
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scan QR code',
                  onPressed: () async {
                    final scanned = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const QrScannerScreen(),
                      ),
                    );
                    if (scanned != null && scanned.isNotEmpty) {
                      _contactIdController.text = scanned;
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contactNameController,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _addingContact ? null : _addContact,
            child: _addingContact
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Add contact'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _nextPage,
            child: const Text('Skip for now'),
          ),
        ],
      ),
    );
  }

  Widget _onionIdStep(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.fingerprint_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your Prysm ID',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This is your unique address on Tor. Friends use it to add you. '
            'It is a Base58 encoding of your .onion hidden service address.',
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          Center(
            child: PrysmIdQrCode(data: _prysmId, size: 160),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _truncateId(_prysmId),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    tooltip: 'Copy ID',
                    onPressed: _copyPrysmId,
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code),
                    tooltip: 'Show full QR',
                    onPressed: () => showPrysmIdQrDialog(context, _prysmId),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Share this ID or QR so others can message you. You can always '
            'find it in your profile or the sidebar.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
