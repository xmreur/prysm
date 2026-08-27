import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

String callMessageLabel(AppLocalizations l10n, PrysmCallMessage message) {
  final direction = message.direction == 'outbound' ? l10n.outgoing : l10n.incoming;
  if (message.callStatus == 'completed') {
    return l10n.directionCallDuration(
      direction,
      formatCallMessageDuration(message.durationMs),
    );
  }
  return l10n.directionCallStatus(
    direction,
    _prettyCallStatus(l10n, message.callStatus),
  );
}

String _prettyCallStatus(AppLocalizations l10n, String status) {
  switch (status) {
    case 'completed':
      return l10n.completed;
    case 'missed':
      return l10n.missed;
    case 'declined':
      return l10n.declined;
    case 'failed':
      return l10n.failed;
    default:
      return status;
  }
}

String formatCallMessageDuration(int durationMs) {
  final seconds = (durationMs ~/ 1000).clamp(0, Duration.secondsPerDay * 99);
  final minutes = seconds ~/ 60;
  final secs = seconds % 60;
  if (minutes > 0) {
    return '${minutes}m ${secs.toString().padLeft(2, '0')}s';
  }
  return '${secs}s';
}

/// System-style call summary row, shared by 1:1 and group timelines.
class CallMessageBubble extends StatelessWidget {
  const CallMessageBubble({required this.message, super.key});

  final PrysmCallMessage message;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final isMissed = message.callStatus == 'missed';
    final createdAt = message.createdAt;
    final timeString = createdAt != null
        ? '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}'
        : '';

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PrysmIcons.phone,
              size: 16,
              color: isMissed ? tokens.danger : tokens.textSecondary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                callMessageLabel(context.l10n, message),
                style: context.prysmStyle.captionStyle.copyWith(
                  color: isMissed ? tokens.danger : tokens.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (timeString.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                timeString,
                style: context.prysmStyle.captionStyle.copyWith(
                  color: tokens.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
