import 'package:flutter/widgets.dart';
import 'package:prysm/app/conversation_list_repository.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/storage_media_item.dart';
import 'package:prysm/screens/file_preview_screen.dart';
import 'package:prysm/screens/widgets/image_viewer_screen.dart';
import 'package:prysm/screens/widgets/view_once_image_screen.dart';
import 'package:prysm/screens/widgets/voice_message_bubble.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/services/storage_media_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_tabs.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/format_file_size.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/readable_file_policy.dart';
import 'package:prysm/l10n/l10n_enum_extensions.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class StorageMediaBrowserScreen extends StatefulWidget {
  final VoidCallback onClose;
  final String userId;
  final KeyManager keyManager;
  final int? mediaItemCount;

  const StorageMediaBrowserScreen({
    required this.onClose,
    required this.userId,
    required this.keyManager,
    this.mediaItemCount,
    super.key,
  });

  @override
  State<StorageMediaBrowserScreen> createState() =>
      _StorageMediaBrowserScreenState();
}

class _StorageMediaBrowserScreenState extends State<StorageMediaBrowserScreen> {
  static const _pageSize = 50;

  late final PrysmTabController _tabController;
  late final GroupService _groupService;
  StorageMediaService? _mediaService;

  final Map<ChatMediaFilter, ScrollController> _scrollControllers = {};
  final Map<ChatMediaFilter, List<StorageMediaItem>> _itemsByFilter = {};
  final Map<ChatMediaFilter, bool> _hasMoreByFilter = {};
  final Map<ChatMediaFilter, bool> _loadingByFilter = {};
  final Map<ChatMediaFilter, int?> _countsByFilter = {};

  bool _bootstrapping = true;

  @override
  void initState() {
    super.initState();
    _tabController = PrysmTabController(length: 4);
    _groupService = GroupService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    for (final filter in ChatMediaFilter.values) {
      final controller = ScrollController();
      controller.addListener(() => _onScroll(filter));
      _scrollControllers[filter] = controller;
      _itemsByFilter[filter] = [];
      _hasMoreByFilter[filter] = true;
      _loadingByFilter[filter] = false;
    }
    _tabController.addListener(() => _ensureLoaded(_currentFilter));
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final repo = const ConversationListRepository();
      final userMaps = await repo.getUsers();
      final groups = await _groupService.getGroups();

      final contactNames = <String, String>{};
      for (final map in userMaps) {
        final id = map['id'] as String;
        final customName = map['customName'] as String?;
        final name = map['name'] as String? ?? id;
        contactNames[id] =
            (customName != null && customName.isNotEmpty) ? customName : name;
      }

      final groupNames = {for (final g in groups) g.id: g.name};

      _mediaService = StorageMediaService(
        keyManager: widget.keyManager,
        userId: widget.userId,
        groupService: _groupService,
        contactNames: contactNames,
        groupNames: groupNames,
      );

      for (final filter in ChatMediaFilter.values) {
        _countsByFilter[filter] = await _mediaService!.countMedia(filter);
      }

      if (!mounted) return;
      setState(() => _bootstrapping = false);
      await _ensureLoaded(ChatMediaFilter.all);
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootstrapping = false);
      showPrysmToast(context, 'Could not load media: $e');
    }
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
    if (_mediaService == null) return;
    if (_itemsByFilter[filter]!.isEmpty && _hasMoreByFilter[filter]!) {
      await _loadMore(filter);
    }
  }

  Future<void> _loadMore(ChatMediaFilter filter) async {
    final service = _mediaService;
    if (service == null ||
        _loadingByFilter[filter]! ||
        !_hasMoreByFilter[filter]!) {
      return;
    }
    setState(() => _loadingByFilter[filter] = true);

    try {
      final existing = _itemsByFilter[filter]!;
      final beforeTimestamp =
          existing.isEmpty ? null : existing.last.timestamp;
      final beforeId = existing.isEmpty ? null : existing.last.id;
      final page = await service.loadPage(
        filter,
        limit: _pageSize,
        beforeTimestamp: beforeTimestamp,
        beforeId: beforeId,
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

  Future<void> _handleTap(StorageMediaItem item) async {
    final service = _mediaService;
    if (service == null) return;

    if (item.isImage) {
      await _openImage(item, service);
    } else if (item.isVoice) {
      await _openVoice(item, service);
    } else {
      await _openFile(item, service);
    }
  }

  Future<void> _openImage(
    StorageMediaItem item,
    StorageMediaService service,
  ) async {
    if (item.isViewOnce && !item.viewed) {
      final isSender = item.senderId == widget.userId;
      if (isSender) return;

      try {
        final bytes = await service.decryptImageBytes(item);
        if (!mounted) return;
        await Navigator.push(
          context,
          PrysmPageRoute(
            page: ViewOnceImageScreen(imageBytes: bytes),
          ),
        );
        await MessagesDb.markViewOnceViewed(
          item.id,
          groupId: item.groupId,
        );
        if (!mounted) return;
        _removeItem(item);
      } catch (e) {
        if (!mounted) return;
        showPrysmToast(context, 'Could not open image: $e');
      }
      return;
    }

    await Navigator.push(
      context,
      PrysmPageRoute(
        page: ImageViewerScreen.deferred(
          messageId: item.id,
          decryptFromDb: service.decryptCallbackForItem(item),
        ),
      ),
    );
  }

  Future<void> _openFile(
    StorageMediaItem item,
    StorageMediaService service,
  ) async {
    final fileName = item.fileName ?? 'file';
    final category = ReadableFilePolicy.categorize(fileName);
    await Navigator.push(
      context,
      PrysmPageRoute(
        page: FilePreviewScreen(
          fileName: fileName,
          fileSize: item.fileSize,
          category: category,
          bytesFuture: service.resolveFileBytes(item),
        ),
      ),
    );
  }

  Future<void> _openVoice(
    StorageMediaItem item,
    StorageMediaService service,
  ) async {
    try {
      final playback = await service.resolveVoicePlayback(item);
      if (!mounted) return;
      final message = service.fileMessageForVoice(item, playback);
      await showPrysmSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: VoiceMessageBubble(
              message: message,
              isSentByMe: item.senderId == widget.userId,
              timeString: _formatTime(item.timestamp),
              tickWidget: const SizedBox.shrink(),
              decryptAudio: service.voiceDecryptCallback(item),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not play voice message: $e');
    }
  }

  Future<void> _deleteItem(StorageMediaItem item) async {
    final service = _mediaService;
    if (service == null) return;

    final label = item.fileName ?? (item.isImage ? 'Photo' : 'Media');
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: context.l10n.deleteMedia,
      content: Text(
        context.l10n.deleteMediaFromConversation(label, item.conversationLabel),
      ),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.delete,
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;

    try {
      await service.deleteLocally(item);
      if (!mounted) return;
      _removeItem(item);
      showPrysmToast(context, context.l10n.mediaDeleted);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not delete media: $e');
    }
  }

  void _removeItem(StorageMediaItem item) {
    setState(() {
      for (final filter in ChatMediaFilter.values) {
        _itemsByFilter[filter] =
            _itemsByFilter[filter]!.where((i) => i.id != item.id).toList();
        final count = _countsByFilter[filter];
        if (count != null && count > 0) {
          _countsByFilter[filter] = count - 1;
        }
      }
    });
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  IconData _iconFor(StorageMediaItem item) {
    if (item.isImage) return PrysmIcons.imageOutlined;
    if (item.isVoice) return PrysmIcons.micOutlined;
    return PrysmIcons.insertDriveFileOutlined;
  }

  Widget _buildThumbnail(StorageMediaItem item) {
    if (!item.isImage || item.isViewOnce) {
      return Icon(_iconFor(item));
    }

    final service = _mediaService;
    if (service == null) return Icon(_iconFor(item));

    return FutureBuilder(
      future: ImageAttachmentCache.resolve(
        messageId: item.id,
        decrypt: service.decryptCallbackForItem(item),
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 24,
            height: 24,
            child: PrysmProgressIndicator(size: 18),
          );
        }
        final cached = snapshot.data!;
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            cached.bytes,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }

  Widget _buildList(ChatMediaFilter filter) {
    final items = _itemsByFilter[filter]!;
    final loadingMore = _loadingByFilter[filter]!;
    final hasMore = _hasMoreByFilter[filter]!;

    if (items.isEmpty && !loadingMore && !_bootstrapping) {
      return Center(
        child: Text(
          'No media stored',
          style: TextStyle(color: context.prysmStyle.tokens.textMuted),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollControllers[filter],
      padding: const EdgeInsets.all(PrysmTokens.spacing16),
      itemCount: items.length + (loadingMore || hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: PrysmProgressIndicator(size: 24)),
          );
        }

        final item = items[index];
        final sizeLabel = item.fileSize != null
            ? formatFileSize(item.fileSize!)
            : 'Unknown size';

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: PrysmListRow(
            leading: SizedBox(width: 40, height: 40, child: _buildThumbnail(item)),
            title: item.fileName ?? (item.isImage ? 'Photo' : 'Media'),
            subtitle:
                '${item.conversationLabel} · $sizeLabel · ${_formatDate(item.timestamp)}',
            onTap: () => _handleTap(item),
            trailing: PrysmIconButton(
              icon: PrysmIcons.deleteOutline,
              onPressed: () => _deleteItem(item),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.mediaItemCount ??
        _countsByFilter[ChatMediaFilter.all];
    final subtitle = count != null ? '$count items' : null;

    return PrysmPage(
      title: context.l10n.chatMedia,
      subtitle: subtitle,
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      bottom: PrysmTabBar(
        controller: _tabController,
        tabs: ChatMediaFilter.values
            .map((filter) => filter.localizedLabel(context.l10n))
            .toList(),
      ),
      body: _bootstrapping
          ? const Center(child: PrysmProgressIndicator())
          : PrysmTabBarView(
              controller: _tabController,
              children: ChatMediaFilter.values
                  .map((filter) => _buildList(filter))
                  .toList(),
            ),
    );
  }
}
