import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

/// A group call this member is not in is running: offer to join it.
class GroupCallJoinBanner extends StatelessWidget {
  const GroupCallJoinBanner({required this.onJoin, super.key});

  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(PrysmIcons.phone, size: 16, color: tokens.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.groupCallInProgress,
                style: context.prysmStyle.captionStyle.copyWith(
                  color: tokens.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            PrysmButton(label: context.l10n.joinCall, onPressed: onJoin),
          ],
        ),
      ),
    );
  }
}
