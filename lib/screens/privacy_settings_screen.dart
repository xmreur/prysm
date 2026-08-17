import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_radio.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/l10n/l10n_enum_extensions.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/screens/panic_pin_settings_screen.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
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
  bool _refuseUnknownSenders = false;
  GroupInviteMode _groupInviteMode = SettingsService().groupInviteMode;

  /// True while a mode change is being persisted. Blocks a second selection
  /// from racing the first one's `GroupPendingInviteStore.clear()`.
  bool _applyingInviteMode = false;

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
      _refuseUnknownSenders = settings.refuseUnknownSenders;
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

  Future<void> _onGroupInviteModeChanged(GroupInviteMode? value) async {
    if (value == null || value == _groupInviteMode) return;
    // Reentrancy guard, not decoration. Without it: tap contactsOnly, tap
    // holdAsRequest before the first await returns, and the first invocation
    // resumes with its own captured `value` still == contactsOnly and wipes
    // the store — while the committed mode is the one that allows holding.
    if (_applyingInviteMode) return;
    setState(() {
      _groupInviteMode = value;
      _applyingInviteMode = true;
    });
    try {
      await settings.setGroupInviteMode(value);
      // Re-read what was actually committed instead of trusting `value`: the
      // clear is destructive and must follow the persisted mode, not the
      // intent this closure was created with.
      if (settings.groupInviteMode == GroupInviteMode.contactsOnly) {
        // The mode promises nothing is stored: switching to it discards what
        // was held, so the requests screen cannot keep showing rows the user
        // just asked not to keep.
        await GroupPendingInviteStore.clear();
        // The sidebar caches the pending count and would keep advertising
        // requests that no longer exist; this is the notifier the home screen
        // already listens to for a light reload.
        ConversationRefreshNotifier.instance.notifyInboundMessage();
      }
    } finally {
      if (mounted) setState(() => _applyingInviteMode = false);
    }
  }

  void _onLastSeenToggle(bool value) {
    setState(() => _lastSeen = value);
    _savePrivacySetting('last_seen', value);
  }

  void _onProfilePhotoToggle(bool value) {
    setState(() => _profilePhoto = value);
    _savePrivacySetting('profile_photo', value);
  }

  Future<void> _onRefuseUnknownSendersToggle(bool value) async {
    setState(() => _refuseUnknownSenders = value);
    await settings.setRefuseUnknownSenders(value);
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return PrysmPage(
      title: context.l10n.privacySettings,
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
                    title: context.l10n.showOnlineStatus,
                    subtitle: context.l10n.whenEnabledRecentContactsAreNotifiedWhenYou,
                    value: _showOnlineStatus,
                    onChanged: _onOnlineStatusToggle,
                  ),
                  PrysmSwitchRow(
                    title: context.l10n.readReceipts,
                    value: _readReceipts,
                    onChanged: _onReadReceiptsToggle,
                  ),
                  PrysmSwitchRow(
                    title: context.l10n.typingIndicators,
                    subtitle:
                        context.l10n.whenDisabledYouWontSendOrSeeTypingActivity,
                    value: _typingIndicators,
                    onChanged: _onTypingIndicatorsToggle,
                  ),
                  PrysmSwitchRow(
                    title: context.l10n.lastSeen,
                    value: _lastSeen,
                    onChanged: _onLastSeenToggle,
                  ),
                  PrysmSwitchRow(
                    title: context.l10n.profilePhoto,
                    value: _profilePhoto,
                    onChanged: _onProfilePhotoToggle,
                  ),
                  PrysmSwitchRow(
                    title: context.l10n.refuseMessagesFromNonContacts,
                    subtitle: context.l10n.whenEnabledPeopleWhoAreNotInYour,
                    value: _refuseUnknownSenders,
                    onChanged: _onRefuseUnknownSendersToggle,
                  ),
                ],
              ),
              if (widget.keyManager != null) ...[
                const SizedBox(height: 30),
                Text(context.l10n.groupInvites, style: style.headlineStyle),
                const SizedBox(height: 12),
                PrysmSection(
                  children: [
                    for (final mode in GroupInviteMode.values)
                      PrysmRadioRow<GroupInviteMode>(
                        value: mode,
                        groupValue: _groupInviteMode,
                        title: mode.localizedLabel(context.l10n),
                        subtitle: mode.localizedDescription(context.l10n),
                        onChanged: _applyingInviteMode
                            ? null
                            : _onGroupInviteModeChanged,
                      ),
                  ],
                ),
                const SizedBox(height: 30),
                Text(context.l10n.emergency, style: style.headlineStyle),
                const SizedBox(height: 12),
                PrysmSection(
                  children: [
                    PrysmListRow(
                      leading: const Icon(PrysmIcons.emergencyOutlined),
                      title: context.l10n.panicMode,
                      subtitleWidget: FutureBuilder<bool>(
                        future: PanicPinService.instance.isConfigured(),
                        builder: (context, snapshot) {
                          final configured = snapshot.data == true;
                          return Text(
                            configured
                                ? context.l10n.panicPinConfigured
                                : context.l10n.setSecondaryPanicPin,
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
              Text(context.l10n.privacyInformation, style: style.headlineStyle),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(PrysmTokens.spacing16),
                decoration: BoxDecoration(
                  color: style.tokens.surface,
                  borderRadius:
                      BorderRadius.circular(PrysmTokens.radiusCard),
                ),
                child: Text(
                  context.l10n.privacySettingsBody(settings.name),
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
