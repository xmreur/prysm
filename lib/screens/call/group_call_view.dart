import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/group_call_snapshot.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_tabs.dart';

/// One row of the in-call participant list.
class GroupCallParticipant {
  const GroupCallParticipant({
    required this.onion,
    required this.label,
    required this.muted,
    required this.isSelf,
  });

  final String onion;
  final String label;
  final bool muted;
  final bool isSelf;
}

/// A group call is ringing. Joining is also possible later from the group
/// chat banner, so dismissing is not a decline.
class GroupIncomingCallView extends StatelessWidget {
  const GroupIncomingCallView({
    required this.groupLabel,
    required this.onJoin,
    required this.onDismiss,
    super.key,
  });

  final String groupLabel;
  final VoidCallback onJoin;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ContactAvatar(name: groupLabel, radius: 56),
            const SizedBox(height: 24),
            Text(
              context.l10n.incomingGroupCall,
              style: context.prysmStyle.headlineStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              groupLabel,
              style: context.prysmStyle.headlineStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PrysmButton(
                  label: context.l10n.dismiss,
                  variant: PrysmButtonVariant.secondary,
                  onPressed: onDismiss,
                ),
                const SizedBox(width: 24),
                PrysmButton(
                  label: context.l10n.joinCall,
                  onPressed: onJoin,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class GroupActiveCallView extends StatelessWidget {
  const GroupActiveCallView({
    required this.groupLabel,
    required this.snapshot,
    required this.participants,
    required this.onToggleMute,
    required this.onLeave,
    super.key,
  });

  final String groupLabel;
  final GroupCallSnapshot snapshot;
  final List<GroupCallParticipant> participants;
  final VoidCallback onToggleMute;
  final VoidCallback onLeave;

  String _statusLabel(BuildContext context) {
    switch (snapshot.state) {
      case CallState.connecting:
        return context.l10n.connecting;
      case CallState.ringing:
        return context.l10n.ringing;
      case CallState.active:
        return context.l10n.groupCallParticipantCount(participants.length);
      case CallState.idle:
      case CallState.incoming:
      case CallState.ended:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ContactAvatar(name: groupLabel, radius: 48),
            const SizedBox(height: 16),
            Text(
              groupLabel,
              style: context.prysmStyle.headlineStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(_statusLabel(context), style: context.prysmStyle.titleStyle),
            if (snapshot.listenOnly)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.l10n.youAreListenOnly,
                  textAlign: TextAlign.center,
                  style: context.prysmStyle.bodyStyle.copyWith(
                    color: tokens.textMuted,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                children: [
                  for (final participant in participants)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          ContactAvatar(name: participant.label, radius: 16),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              participant.isSelf
                                  ? context.l10n.you
                                  : participant.label,
                              style: context.prysmStyle.bodyStyle,
                            ),
                          ),
                          Icon(
                            participant.muted
                                ? PrysmIcons.micOff
                                : PrysmIcons.mic,
                            size: 18,
                            color: participant.muted
                                ? tokens.textMuted
                                : tokens.textSecondary,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PrysmFab(
                  icon: snapshot.localMuted
                      ? PrysmIcons.micOff
                      : PrysmIcons.mic,
                  onPressed: snapshot.listenOnly ? null : onToggleMute,
                ),
                const SizedBox(width: 32),
                PrysmFab(
                  icon: PrysmIcons.callEnd,
                  backgroundColor: tokens.danger,
                  onPressed: onLeave,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
