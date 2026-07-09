import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/models/reply_preview_data.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

class QuotedReplyPreview extends StatelessWidget {
  final ReplyPreviewData data;
  final bool isSentByMe;
  final bool compact;
  final String? authorName;
  final VoidCallback? onTap;

  const QuotedReplyPreview({
    required this.data,
    required this.isSentByMe,
    this.compact = false,
    this.authorName,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.prysmStyle;
    final colors = _QuoteColors.resolve(
      theme: theme,
      compact: compact,
      isSentByMe: isSentByMe,
      isUnavailable: data.kind == ReplyPreviewKind.unavailable,
    );

    final content = Container(
      margin: EdgeInsets.only(bottom: compact ? 0 : 4),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact) ...[
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (authorName != null && authorName!.isNotEmpty) ...[
                    Text(
                      authorName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w600,
                        color: colors.accent,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 1),
                  ],
                  Text(
                    data.label,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      height: 1.2,
                      fontStyle:
                          data.kind == ReplyPreviewKind.deleted ||
                                  data.kind == ReplyPreviewKind.unavailable
                              ? FontStyle.italic
                              : FontStyle.normal,
                      color: colors.body,
                    ),
                  ),
                ],
              ),
            ),
            if (!compact && data.kind != ReplyPreviewKind.text) ...[
              const SizedBox(width: 6),
              Icon(
                _iconForKind(data.kind),
                size: 16,
                color: colors.body,
              ),
            ],
          ],
        ),
      ),
    );

    if (onTap == null || data.kind == ReplyPreviewKind.unavailable) {
      return content;
    }

    return PrysmPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: content,
    );
  }

  IconData _iconForKind(ReplyPreviewKind kind) {
    switch (kind) {
      case ReplyPreviewKind.image:
        return PrysmIcons.imageOutlined;
      case ReplyPreviewKind.voice:
        return PrysmIcons.micOutlined;
      case ReplyPreviewKind.file:
        return PrysmIcons.attachFile;
      case ReplyPreviewKind.deleted:
        return PrysmIcons.block;
      case ReplyPreviewKind.unavailable:
        return PrysmIcons.helpOutline;
      case ReplyPreviewKind.text:
        return PrysmIcons.chatBubbleOutline;
    }
  }
}

class _QuoteColors {
  final Color accent;
  final Color body;
  final Color? background;

  const _QuoteColors({
    required this.accent,
    required this.body,
    required this.background,
  });

  static _QuoteColors resolve({
    required PrysmResolvedStyle theme,
    required bool compact,
    required bool isSentByMe,
    required bool isUnavailable,
  }) {
    final tokens = theme.tokens;

    if (compact) {
      return _QuoteColors(
        accent: tokens.accent,
        body: tokens.textSecondary,
        background: const Color(0x00000000),
      );
    }

    final foreground =
        isSentByMe ? tokens.onAccent : tokens.textPrimary;
    return _QuoteColors(
      accent: foreground.withValues(alpha: 0.95),
      body: foreground.withValues(alpha: isUnavailable ? 0.65 : 0.82),
      background: foreground.withValues(alpha: 0.12),
    );
  }
}
