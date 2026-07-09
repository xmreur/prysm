import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/ui/prysm_button.dart';
import 'package:prysm/ui/core/prysm_button.dart';

/// Empty home pane when no conversation is selected.
class EmptyHomeState extends StatelessWidget {
  const EmptyHomeState({
    required this.displayName,
    required this.prysmId,
    required this.contactCount,
    required this.groupCount,
    required this.onCopyId,
    required this.onShowQr,
    required this.onAddContact,
    required this.onCreateGroup,
    this.onScanQr,
    super.key,
  });

  final String displayName;
  final String prysmId;
  final int contactCount;
  final int groupCount;
  final VoidCallback onCopyId;
  final VoidCallback onShowQr;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback? onScanQr;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return Container(
      width: double.infinity,
      color: tokens.background,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: PrysmTokens.spacing24,
            vertical: 40,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/logo.png',
                  height: 72,
                  width: 72,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: PrysmTokens.spacing24),
                Text(
                  'Welcome back, $displayName',
                  style: style.headline,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: PrysmTokens.spacing8),
                Text(
                  'Pick a conversation from the sidebar or start a new one.',
                  style: style.body.copyWith(color: tokens.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: PrysmTokens.spacing24),
                Container(
                  padding: const EdgeInsets.all(PrysmTokens.spacing16),
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    borderRadius:
                        BorderRadius.circular(PrysmTokens.radiusCard),
                  ),
                  child: Row(
                    children: [
                      Icon(PrysmIcons.fingerprintOutlined,
                          color: tokens.accent, size: 22),
                      const SizedBox(width: PrysmTokens.spacing12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Your Prysm ID', style: style.caption),
                            const SizedBox(height: 4),
                            Text(
                              _truncateId(prysmId),
                              style: style.mono,
                            ),
                          ],
                        ),
                      ),
                      PrysmIconButton(
                        icon: PrysmIcons.copyRounded,
                        tooltip: 'Copy ID',
                        onPressed: onCopyId,
                      ),
                      PrysmIconButton(
                        icon: PrysmIcons.qrCode,
                        tooltip: 'Show QR',
                        onPressed: onShowQr,
                      ),
                      if (onScanQr != null)
                        PrysmIconButton(
                          icon: PrysmIcons.qrCodeScanner,
                          tooltip: 'Scan QR',
                          onPressed: onScanQr,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: PrysmTokens.spacing24),
                Row(
                  children: [
                    Expanded(
                      child: _ActionCard(
                        icon: PrysmIcons.personAddAlt1Rounded,
                        title: 'Add contact',
                        subtitle: 'Connect via onion ID',
                        onTap: onAddContact,
                      ),
                    ),
                    const SizedBox(width: PrysmTokens.spacing12),
                    Expanded(
                      child: _ActionCard(
                        icon: PrysmIcons.groupsRounded,
                        title: 'Create group',
                        subtitle: 'Up to 5 members',
                        onTap: onCreateGroup,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: PrysmTokens.spacing24),
                Text(
                  '$contactCount ${contactCount == 1 ? 'contact' : 'contacts'} · '
                  '$groupCount ${groupCount == 1 ? 'group' : 'groups'}',
                  style: style.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _truncateId(String id, {int head = 12, int tail = 8}) {
    if (id.length <= head + tail + 3) return id;
    return '${id.substring(0, head)}…${id.substring(id.length - tail)}';
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return PrysmPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
        ),
        child: Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: tokens.accent, size: 24),
              const SizedBox(height: PrysmTokens.spacing12),
              Text(title, style: style.title),
              const SizedBox(height: 4),
              Text(subtitle, style: style.caption),
            ],
          ),
        ),
      ),
    );
  }
}
