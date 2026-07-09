import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';

bool shouldShowChatDateHeader(List<Message> messages, int index) {
  if (index == 0) return true;
  final msgDate = messages[index].createdAt ?? DateTime.now();
  final currentDay = DateTime(msgDate.year, msgDate.month, msgDate.day);
  final prevDate = messages[index - 1].createdAt ?? DateTime.now();
  final prevDay = DateTime(prevDate.year, prevDate.month, prevDate.day);
  return !currentDay.isAtSameMomentAs(prevDay);
}

class PrysmDateHeader extends StatelessWidget {
  const PrysmDateHeader({required this.date, super.key});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final label = '${date.day}/${date.month}/${date.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PrysmTokens.spacing12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PrysmTokens.spacing12,
            vertical: PrysmTokens.spacing4,
          ),
          decoration: BoxDecoration(
            color: tokens.surfaceElevated,
            borderRadius: BorderRadius.circular(PrysmTokens.radiusChip),
          ),
          child: Text(label, style: style.caption),
        ),
      ),
    );
  }
}
