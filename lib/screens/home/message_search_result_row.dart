import 'package:flutter/widgets.dart';
import 'package:prysm/models/message_search_hit.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';

class MessageSearchResultRow extends StatelessWidget {
  const MessageSearchResultRow({
    required this.hit,
    required this.conversationName,
    required this.timeLabel,
    this.avatarBase64,
    required this.onTap,
    super.key,
  });

  final MessageSearchHit hit;
  final String conversationName;
  final String timeLabel;
  final String? avatarBase64;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final snippet = hit.snippet.isNotEmpty ? hit.snippet : hit.body;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: PrysmListRow(
        onTap: onTap,
        leading: SizedBox(
          width: 48,
          height: 48,
          child: ContactAvatar(
            name: conversationName,
            avatarBase64: avatarBase64,
          ),
        ),
        title: conversationName,
        subtitle: snippet,
        trailingSubtitle: timeLabel,
        trailing: Icon(
          PrysmIcons.search,
          size: 16,
          color: tokens.textMuted,
        ),
      ),
    );
  }
}
