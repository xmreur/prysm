import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/chat_media_service.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/readable_file_policy.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';

class ChatMediaTile extends StatefulWidget {
  final ChatMediaItem item;
  final ChatMediaService mediaService;
  final Map<String, Contact>? contactsById;
  final VoidCallback onTap;
  final VoidCallback onShowInChat;

  const ChatMediaTile({
    required this.item,
    required this.mediaService,
    required this.onTap,
    required this.onShowInChat,
    this.contactsById,
    super.key,
  });

  @override
  State<ChatMediaTile> createState() => _ChatMediaTileState();
}

class _ChatMediaTileState extends State<ChatMediaTile> {
  CachedImage? _thumbnail;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.item.isImage && !widget.item.isViewOnce) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = await ImageAttachmentCache.resolve(
        messageId: widget.item.id,
        decrypt: widget.mediaService.decryptCallbackForItem(widget.item),
      );
      if (!mounted) return;
      setState(() {
        _thumbnail = cached;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: () => _showActions(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildContent(context),
            if (widget.item.isViewOnce && !widget.item.viewed)
              _viewOnceBadge(),
            if (widget.item.isGroup && widget.contactsById != null)
              _senderBadge(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (widget.item.isImage) {
      if (widget.item.isViewOnce) {
        return ColoredBox(
          color: context.prysmStyle.tokens.surfaceElevated,
          child: Icon(
            PrysmIcons.visibilityOutlined,
            color: context.prysmStyle.tokens.textMuted,
            size: 32,
          ),
        );
      }
      if (_thumbnail != null) {
        return Image.memory(
          _thumbnail!.bytes,
          fit: BoxFit.cover,
          cacheWidth: 200,
          cacheHeight: 200,
        );
      }
      if (_loading) {
        return const ColoredBox(
          color: Color(0x12000000),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: PrysmProgressIndicator(size: 20),
            ),
          ),
        );
      }
      if (_error != null) {
        final tokens = context.prysmStyle.tokens;
        return ColoredBox(
          color: Color.lerp(tokens.danger, tokens.surface, 0.85)!,
          child: Icon(
            PrysmIcons.brokenImageOutlined,
            color: tokens.danger,
          ),
        );
      }
      return const ColoredBox(color: Color(0x12000000));
    }

    if (widget.item.isVoice) {
      final tokens = context.prysmStyle.tokens;
      return ColoredBox(
        color: tokens.accentMuted,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              PrysmIcons.mic,
              color: tokens.accent,
              size: 28,
            ),
            const SizedBox(height: 4),
            Text(
              'Voice',
              style: TextStyle(
                fontSize: 11,
                color: tokens.accent,
              ),
            ),
          ],
        ),
      );
    }

    final category = ReadableFilePolicy.categorize(
      widget.item.fileName ?? 'file',
    );
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _iconForCategory(category),
              color: tokens.textPrimary,
              size: 28,
            ),
            const SizedBox(height: 6),
            Text(
              widget.item.fileName ?? 'File',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewOnceBadge() {
    return Positioned(
      top: 6,
      right: 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF000000).withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PrysmIcons.filter1, size: 12, color: Color(0xFFFFFFFF)),
            SizedBox(width: 2),
            Icon(PrysmIcons.visibility, size: 12, color: Color(0xFFFFFFFF)),
          ],
        ),
      ),
    );
  }

  Widget _senderBadge() {
    final contact = widget.contactsById![widget.item.senderId];
    if (contact == null) return const SizedBox.shrink();
    return Positioned(
      left: 4,
      bottom: 4,
      child: ContactAvatar(
        name: contact.displayName,
        avatarBase64: contact.avatarBase64,
        radius: 10,
      ),
    );
  }

  IconData _iconForCategory(FilePreviewCategory category) {
    switch (category) {
      case FilePreviewCategory.pdf:
        return PrysmIcons.pictureAsPdfOutlined;
      case FilePreviewCategory.video:
        return PrysmIcons.videocamOutlined;
      case FilePreviewCategory.audio:
        return PrysmIcons.audiotrackOutlined;
      case FilePreviewCategory.spreadsheet:
        return PrysmIcons.tableChartOutlined;
      case FilePreviewCategory.document:
      case FilePreviewCategory.presentation:
        return PrysmIcons.descriptionOutlined;
      case FilePreviewCategory.text:
        return PrysmIcons.articleOutlined;
      case FilePreviewCategory.blocked:
        return PrysmIcons.blockOutlined;
      case FilePreviewCategory.binary:
        return PrysmIcons.insertDriveFileOutlined;
    }
  }

  void _showActions(BuildContext context) {
    showPrysmSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PrysmListRow(
              leading: const Icon(PrysmIcons.chatBubbleOutline),
              title: 'Show in chat',
              onTap: () {
                Navigator.pop(ctx);
                widget.onShowInChat();
              },
            ),
          ],
        ),
      ),
    );
  }
}
