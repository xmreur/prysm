import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/widgets/chat_media_tile.dart';
import 'package:prysm/services/chat_media_service.dart';
import 'package:prysm/ui/core/prysm_progress.dart';

class ChatMediaGrid extends StatelessWidget {
  final List<ChatMediaItem> items;
  final ChatMediaService mediaService;
  final Map<String, Contact>? contactsById;
  final ScrollController scrollController;
  final bool loadingMore;
  final bool hasMore;
  final void Function(ChatMediaItem item) onItemTap;
  final void Function(ChatMediaItem item) onShowInChat;

  const ChatMediaGrid({
    required this.items,
    required this.mediaService,
    required this.scrollController,
    required this.onItemTap,
    required this.onShowInChat,
    this.contactsById,
    this.loadingMore = false,
    this.hasMore = true,
    super.key,
  });

  int _columnCount(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 900) return 5;
    if (width >= 600) return 4;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && !loadingMore) {
      return Center(
        child: Text(
          'No media in this conversation yet',
          style: TextStyle(color: context.prysmStyle.tokens.textMuted),
        ),
      );
    }

    final columns = _columnCount(context);
    final tileCount = items.length + (loadingMore || hasMore ? 1 : 0);

    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: tileCount,
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: PrysmProgressIndicator(size: 20),
              ),
            ),
          );
        }

        final item = items[index];
        return ChatMediaTile(
          item: item,
          mediaService: mediaService,
          contactsById: contactsById,
          onTap: () => onItemTap(item),
          onShowInChat: () => onShowInChat(item),
        );
      },
    );
  }
}
