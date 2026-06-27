import 'package:flutter/material.dart';
import 'package:prysm/models/reply_preview_data.dart';

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
    final theme = Theme.of(context);
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: content,
      ),
    );
  }

  IconData _iconForKind(ReplyPreviewKind kind) {
    switch (kind) {
      case ReplyPreviewKind.image:
        return Icons.image_outlined;
      case ReplyPreviewKind.voice:
        return Icons.mic_outlined;
      case ReplyPreviewKind.file:
        return Icons.attach_file;
      case ReplyPreviewKind.deleted:
        return Icons.block;
      case ReplyPreviewKind.unavailable:
        return Icons.help_outline;
      case ReplyPreviewKind.text:
        return Icons.chat_bubble_outline;
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
    required ThemeData theme,
    required bool compact,
    required bool isSentByMe,
    required bool isUnavailable,
  }) {
    final scheme = theme.colorScheme;

    if (compact) {
      return _QuoteColors(
        accent: scheme.primary,
        body: scheme.onSurfaceVariant,
        background: Colors.transparent,
      );
    }

    final foreground = isSentByMe ? scheme.onPrimary : scheme.onSecondary;
    return _QuoteColors(
      accent: foreground.withValues(alpha: 0.95),
      body: foreground.withValues(alpha: isUnavailable ? 0.65 : 0.82),
      background: foreground.withValues(alpha: 0.12),
    );
  }
}
