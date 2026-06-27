import 'package:flutter/material.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/screens/file_preview_screen.dart';
import 'package:prysm/screens/widgets/chat_media_grid.dart';
import 'package:prysm/screens/widgets/image_viewer_screen.dart';
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/services/chat_media_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/readable_file_policy.dart';

class ChatMediaGalleryScreen extends StatefulWidget {
  final String title;
  final ChatMediaService mediaService;
  final String userId;
  final Map<String, Contact>? contactsById;
  final ValueChanged<String>? onShowInChat;

  const ChatMediaGalleryScreen._({
    required this.title,
    required this.mediaService,
    required this.userId,
    this.contactsById,
    this.onShowInChat,
    super.key,
  });

  factory ChatMediaGalleryScreen.direct({
    required Contact peer,
    required String userId,
    required KeyManager keyManager,
    ValueChanged<String>? onShowInChat,
    Key? key,
  }) {
    return ChatMediaGalleryScreen._(
      key: key,
      title: peer.displayName,
      userId: userId,
      onShowInChat: onShowInChat,
      mediaService: ChatMediaService.direct(
        keyManager: keyManager,
        userId: userId,
        peerId: peer.id,
      ),
    );
  }

  factory ChatMediaGalleryScreen.group({
    required Group group,
    required String userId,
    required KeyManager keyManager,
    required GroupService groupService,
    required List<Contact> contacts,
    int? joinedAt,
    ValueChanged<String>? onShowInChat,
    Key? key,
  }) {
    final contactsById = {for (final c in contacts) c.id: c};
    return ChatMediaGalleryScreen._(
      key: key,
      title: group.name,
      userId: userId,
      contactsById: contactsById,
      onShowInChat: onShowInChat,
      mediaService: ChatMediaService.group(
        keyManager: keyManager,
        userId: userId,
        groupId: group.id,
        groupService: groupService,
        joinedAt: joinedAt,
      ),
    );
  }

  @override
  State<ChatMediaGalleryScreen> createState() => _ChatMediaGalleryScreenState();
}

class _ChatMediaGalleryScreenState extends State<ChatMediaGalleryScreen>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 50;

  late final TabController _tabController;
  final Map<ChatMediaFilter, ScrollController> _scrollControllers = {};
  final Map<ChatMediaFilter, List<ChatMediaItem>> _itemsByFilter = {};
  final Map<ChatMediaFilter, bool> _hasMoreByFilter = {};
  final Map<ChatMediaFilter, bool> _loadingByFilter = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    for (final filter in ChatMediaFilter.values) {
      final controller = ScrollController();
      controller.addListener(() => _onScroll(filter));
      _scrollControllers[filter] = controller;
      _itemsByFilter[filter] = [];
      _hasMoreByFilter[filter] = true;
      _loadingByFilter[filter] = false;
    }
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _ensureLoaded(_currentFilter);
      }
    });
    _ensureLoaded(ChatMediaFilter.all);
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  ChatMediaFilter get _currentFilter =>
      ChatMediaFilter.values[_tabController.index];

  void _onScroll(ChatMediaFilter filter) {
    final controller = _scrollControllers[filter];
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMore(filter);
    }
  }

  Future<void> _ensureLoaded(ChatMediaFilter filter) async {
    if (_itemsByFilter[filter]!.isEmpty && _hasMoreByFilter[filter]!) {
      await _loadMore(filter);
    }
  }

  Future<void> _loadMore(ChatMediaFilter filter) async {
    if (_loadingByFilter[filter]! || !_hasMoreByFilter[filter]!) return;
    setState(() => _loadingByFilter[filter] = true);

    try {
      final existing = _itemsByFilter[filter]!;
      final beforeTimestamp =
          existing.isEmpty ? null : existing.last.timestamp;
      final page = await widget.mediaService.loadPage(
        filter,
        limit: _pageSize,
        beforeTimestamp: beforeTimestamp,
      );

      if (!mounted) return;
      setState(() {
        _itemsByFilter[filter] = [...existing, ...page];
        _hasMoreByFilter[filter] = page.length >= _pageSize;
        _loadingByFilter[filter] = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingByFilter[filter] = false);
    }
  }

  void _handleShowInChat(ChatMediaItem item) {
    if (widget.onShowInChat != null) {
      widget.onShowInChat!(item.id);
    }
    Navigator.of(context).pop(item.id);
  }

  Future<void> _handleTap(ChatMediaItem item) async {
    if (item.isImage) {
      await _openImage(item);
    } else if (item.isVoice) {
      await _openVoice(item);
    } else {
      await _openFile(item);
    }
  }

  Future<void> _openImage(ChatMediaItem item) async {
    if (item.isViewOnce && !item.viewed) {
      final isSender = item.senderId == widget.userId;
      if (isSender) return;

      try {
        final bytes = await widget.mediaService.decryptImageBytes(item);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ViewOnceImageScreen(imageBytes: bytes),
          ),
        );
        await MessagesDb.markViewOnceViewed(
          item.id,
          groupId: item.isGroup ? widget.mediaService.groupId : null,
        );
        if (!mounted) return;
        _removeItem(item);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open image: $e')),
        );
      }
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen.deferred(
          messageId: item.id,
          decryptFromDb: widget.mediaService.decryptCallbackForItem(item),
        ),
      ),
    );
  }

  Future<void> _openFile(ChatMediaItem item) async {
    final fileName = item.fileName ?? 'file';
    final category = ReadableFilePolicy.categorize(fileName);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FilePreviewScreen(
          fileName: fileName,
          fileSize: item.fileSize,
          category: category,
          bytesFuture: widget.mediaService.resolveFileBytes(item),
        ),
      ),
    );
  }

  Future<void> _openVoice(ChatMediaItem item) async {
    try {
      final playback = await widget.mediaService.resolveVoicePlayback(item);
      if (!mounted) return;
      final message = widget.mediaService.fileMessageForVoice(item, playback);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: VoiceMessageBubble(
              message: message,
              isSentByMe: item.senderId == widget.userId,
              timeString: _formatTime(item.timestamp),
              tickWidget: const SizedBox.shrink(),
              decryptAudio: widget.mediaService.voiceDecryptCallback(),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play voice message: $e')),
      );
    }
  }

  void _removeItem(ChatMediaItem item) {
    setState(() {
      for (final filter in ChatMediaFilter.values) {
        _itemsByFilter[filter] =
            _itemsByFilter[filter]!.where((i) => i.id != item.id).toList();
      }
    });
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Shared Media'),
            Text(
              widget.title,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Photos'),
            Tab(text: 'Files'),
            Tab(text: 'Voice'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: ChatMediaFilter.values.map((filter) {
          return ChatMediaGrid(
            items: _itemsByFilter[filter]!,
            mediaService: widget.mediaService,
            contactsById: widget.contactsById,
            scrollController: _scrollControllers[filter]!,
            loadingMore: _loadingByFilter[filter]!,
            hasMore: _hasMoreByFilter[filter]!,
            onItemTap: _handleTap,
            onShowInChat: _handleShowInChat,
          );
        }).toList(),
      ),
    );
  }
}
