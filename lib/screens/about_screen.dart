import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';

class AboutScreen extends StatelessWidget {
  final VoidCallback onClose;

  const AboutScreen({required this.onClose, super.key});

  static final settings = SettingsService();

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return PrysmPage(
      title: 'About ${settings.name}',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: onClose,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(PrysmTokens.spacing24),
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
                      Container(
                        padding: const EdgeInsets.all(PrysmTokens.spacing16),
                        decoration: BoxDecoration(
                          color: tokens.accent.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Image.asset(
                          'assets/logo.png',
                          height: 80,
                          width: 80,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        settings.name,
                        style: style.headlineStyle.copyWith(fontSize: 28),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        settings.description,
                        style: style.bodyStyle.copyWith(color: tokens.textMuted),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Version ${settings.version}',
                        style: style.captionStyle,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              PrysmSection(
                header: 'Developers & Team',
                children: [
                  PrysmListRow(
                    leading: _teamIcon(
                      const Color(0xFF2196F3),
                      PrysmIcons.code,
                    ),
                    title: 'xmreur',
                    subtitle: 'Lead Developer',
                  ),
                  PrysmListRow(
                    leading: _teamIcon(
                      const Color(0xFF4CAF50),
                      PrysmIcons.security,
                    ),
                    title: 'Security Team',
                    subtitle: 'Encryption & Privacy',
                  ),
                  PrysmListRow(
                    leading: _teamIcon(
                      const Color(0xFF9C27B0),
                      PrysmIcons.designServices,
                    ),
                    title: 'UI/UX Team',
                    subtitle: 'User Interface Design',
                  ),
                  PrysmListRow(
                    leading: _teamIcon(
                      const Color(0xFFFF9800),
                      PrysmIcons.troubleshootRounded,
                    ),
                    title: 'Testers Team',
                    subtitle: 'Bug finding & Feature suggestions',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _infoCard(
                context,
                title: 'About This App',
                body:
                    '${settings.name} is a secure messaging application that prioritizes your privacy and security. '
                    'Built with end-to-end encryption and Tor network integration, ${settings.name} ensures that your '
                    'conversations remain private and secure.\n\n'
                    'Features:\n'
                    '• End-to-end encryption\n'
                    '• Tor network integration\n'
                    '• Anonymous messaging\n'
                    '• Cross-platform support\n'
                    '• Dark theme support\n'
                    '• No data collection\n\n'
                    'Developed with ❤️ by xmreur and the ${settings.name} team.',
              ),
              const SizedBox(height: 20),
              _infoCard(
                context,
                title: 'Legal',
                body:
                    'This application is provided "as is" without any warranties. '
                    'The developers are not responsible for any damages or losses '
                    'arising from the use of this application.\n\n'
                    '© 2025 ${settings.name} Team. All rights reserved.',
                muted: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teamIcon(Color color, IconData icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required String title,
    required String body,
    bool muted = false,
  }) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return Container(
      padding: const EdgeInsets.all(PrysmTokens.spacing16),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: style.headlineStyle),
          const SizedBox(height: 12),
          Text(
            body,
            style: style.bodyStyle.copyWith(
              height: 1.5,
              color: muted ? tokens.textMuted : null,
              fontSize: muted ? 14 : null,
            ),
          ),
        ],
      ),
    );
  }
}
