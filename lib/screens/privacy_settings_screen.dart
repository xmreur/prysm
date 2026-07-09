import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/screens/panic_pin_settings_screen.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final KeyManager? keyManager;

  const PrivacySettingsScreen({
    required this.onClose,
    this.keyManager,
    super.key,
  });

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  static final settings = SettingsService();

  bool _showOnlineStatus = true;
  bool _readReceipts = true;
  bool _typingIndicators = true;
  bool _lastSeen = true;
  bool _profilePhoto = true;

  @override
  void initState() {
    super.initState();
    _loadPrivacySettings();
  }

  Future<void> _loadPrivacySettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showOnlineStatus = prefs.getBool('show_online_status') ?? true;
      _readReceipts = settings.sendReadReceipts;
      _typingIndicators = settings.enableTypingIndicators;
      _lastSeen = prefs.getBool('last_seen') ?? true;
      _profilePhoto = prefs.getBool('profile_photo') ?? true;
    });
  }

  Future<void> _savePrivacySetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _onOnlineStatusToggle(bool value) {
    setState(() => _showOnlineStatus = value);
    _savePrivacySetting('show_online_status', value);
    settings.setShowOnlineStatus(value);
  }

  Future<void> _onReadReceiptsToggle(bool value) async {
    setState(() => _readReceipts = value);
    await settings.setSendReadReceipts(value);
  }

  Future<void> _onTypingIndicatorsToggle(bool value) async {
    setState(() => _typingIndicators = value);
    await settings.setEnableTypingIndicators(value);
  }

  void _onLastSeenToggle(bool value) {
    setState(() => _lastSeen = value);
    _savePrivacySetting('last_seen', value);
  }

  void _onProfilePhotoToggle(bool value) {
    setState(() => _profilePhoto = value);
    _savePrivacySetting('profile_photo', value);
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return PrysmPage(
      title: 'Privacy Settings',
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrysmSection(
                children: [
                  PrysmSwitchRow(
                    title: 'Show Online Status',
                    subtitle:
                        'When enabled, recent contacts are notified when you come online so they can deliver pending messages faster.',
                    value: _showOnlineStatus,
                    onChanged: _onOnlineStatusToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Read Receipts',
                    value: _readReceipts,
                    onChanged: _onReadReceiptsToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Typing Indicators',
                    subtitle:
                        "When disabled, you won't send or see typing activity in chats.",
                    value: _typingIndicators,
                    onChanged: _onTypingIndicatorsToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Last Seen',
                    value: _lastSeen,
                    onChanged: _onLastSeenToggle,
                  ),
                  PrysmSwitchRow(
                    title: 'Profile Photo',
                    value: _profilePhoto,
                    onChanged: _onProfilePhotoToggle,
                  ),
                ],
              ),
              if (widget.keyManager != null) ...[
                const SizedBox(height: 30),
                Text('Emergency', style: style.headlineStyle),
                const SizedBox(height: 12),
                PrysmSection(
                  children: [
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.emergencyOutlined),
                      title: 'Panic mode',
                      subtitleWidget: FutureBuilder<bool>(
                        future: PanicPinService.instance.isConfigured(),
                        builder: (context, snapshot) {
                          final configured = snapshot.data == true;
                          return Text(
                            configured
                                ? 'Panic PIN configured'
                                : 'Set a secondary panic PIN',
                            style: style.captionStyle,
                          );
                        },
                      ),
                      trailing: const Icon(PrysmIcons.chevronRight),
                      onTap: () {
                        Navigator.push(
                          context,
                          PrysmPageRoute(
                            page: PanicPinSettingsScreen(
                              keyManager: widget.keyManager!,
                              onClose: () => Navigator.pop(context),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 30),
              Text('Privacy Information', style: style.headlineStyle),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(PrysmTokens.spacing16),
                decoration: BoxDecoration(
                  color: style.tokens.surface,
                  borderRadius:
                      BorderRadius.circular(PrysmTokens.radiusCard),
                ),
                child: Text(
                  'These settings help you control your privacy on ${settings.name}. '
                  'Your choices will be applied across all your conversations.',
                  style: style.bodyStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
