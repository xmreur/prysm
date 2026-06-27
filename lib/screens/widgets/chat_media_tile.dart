import 'package:flutter/material.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/chat_media_service.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/readable_file_policy.dart';

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
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.visibility_outlined,
            color: Theme.of(context).hintColor,
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
          color: Colors.black12,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      if (_error != null) {
        return ColoredBox(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        );
      }
      return const ColoredBox(color: Colors.black12);
    }

    if (widget.item.isVoice) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mic,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              size: 28,
            ),
            const SizedBox(height: 4),
            Text(
              'Voice',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      );
    }

    final category = ReadableFilePolicy.categorize(
      widget.item.fileName ?? 'file',
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _iconForCategory(category),
              color: Theme.of(context).colorScheme.onSecondaryContainer,
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
                color: Theme.of(context).colorScheme.onSecondaryContainer,
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
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_1, size: 12, color: Colors.white),
            SizedBox(width: 2),
            Icon(Icons.visibility, size: 12, color: Colors.white),
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
        return Icons.picture_as_pdf_outlined;
      case FilePreviewCategory.video:
        return Icons.videocam_outlined;
      case FilePreviewCategory.audio:
        return Icons.audiotrack_outlined;
      case FilePreviewCategory.spreadsheet:
        return Icons.table_chart_outlined;
      case FilePreviewCategory.document:
      case FilePreviewCategory.presentation:
        return Icons.description_outlined;
      case FilePreviewCategory.text:
        return Icons.article_outlined;
      case FilePreviewCategory.blocked:
        return Icons.block_outlined;
      case FilePreviewCategory.binary:
        return Icons.insert_drive_file_outlined;
    }
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Show in chat'),
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
