import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/screens/widgets/jump_to_bottom_fab.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:prysm/util/chat_scroll.dart';

/// In-house chat message list — no flutter_chat_ui.
class PrysmChatList extends StatefulWidget {
  const PrysmChatList({
    required this.controller,
    required this.scrollController,
    required this.itemBuilder,
    this.onLoadMore,
    this.showJumpToBottom = true,
    this.onStickToBottomChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    super.key,
  });

  final PrysmChatMessageList controller;
  final ScrollController scrollController;
  final Widget Function(BuildContext context, PrysmMessage message, int index)
      itemBuilder;
  final Future<void> Function()? onLoadMore;
  final bool showJumpToBottom;
  final ValueChanged<bool>? onStickToBottomChanged;
  final EdgeInsets padding;

  @override
  State<PrysmChatList> createState() => _PrysmChatListState();
}

class _PrysmChatListState extends State<PrysmChatList> {
  final _messageKeys = <String, GlobalKey>{};
  bool _loadingMore = false;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _attachScrollMethods();
  }

  @override
  void didUpdateWidget(covariant PrysmChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.detachScrollMethods();
      _messageKeys.clear();
      _attachScrollMethods();
    }
  }

  void _attachScrollMethods() {
    widget.controller.attachScrollMethods(
      scrollToMessageId: _scrollToMessageId,
      scrollToIndex: _scrollToIndex,
    );
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    widget.controller.detachScrollMethods();
    super.dispose();
  }

  void _onScroll() {
    final atBottom = isChatScrolledToBottom(widget.scrollController);
    if (atBottom != _atBottom) {
      _atBottom = atBottom;
      widget.onStickToBottomChanged?.call(atBottom);
      if (mounted) setState(() {});
    }

    if (widget.onLoadMore == null || _loadingMore) return;
    if (!widget.scrollController.hasClients) return;
    if (widget.scrollController.position.pixels > 120) return;
    _loadingMore = true;
    widget.onLoadMore!().whenComplete(() {
      _loadingMore = false;
    });
  }

  Future<void> _scrollToMessageId(
    String messageId, {
    Duration duration = const Duration(milliseconds: 250),
    double alignment = 0,
  }) async {
    final index =
        widget.controller.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    await _scrollToIndex(index, duration: duration, alignment: alignment);
  }

  Future<void> _scrollToIndex(
    int index, {
    Duration duration = const Duration(milliseconds: 250),
    double alignment = 0,
  }) async {
    if (!widget.scrollController.hasClients) return;
    final messages = widget.controller.messages;
    if (index < 0 || index >= messages.length) return;

    final key = _keyForMessage(messages[index].id);
    final ctx = key.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: duration,
        alignment: alignment,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
      return;
    }
    final max = widget.scrollController.position.maxScrollExtent;
    final fraction = messages.isEmpty ? 0.0 : index / messages.length;
    final target = max * fraction;
    if (duration == Duration.zero) {
      widget.scrollController.jumpTo(target.clamp(0.0, max));
    } else {
      await widget.scrollController.animateTo(
        target.clamp(0.0, max),
        duration: duration,
        curve: Curves.easeOut,
      );
    }
  }

  void _jumpToBottom() {
    if (!widget.scrollController.hasClients) return;
    widget.scrollController.animateTo(
      widget.scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    _atBottom = true;
    widget.onStickToBottomChanged?.call(true);
    setState(() {});
  }

  GlobalKey _keyForMessage(String messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  void _pruneMessageKeys(List<PrysmMessage> messages) {
    final liveIds = messages.map((m) => m.id).toSet();
    _messageKeys.removeWhere((id, _) => !liveIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.controller.messages;
    _pruneMessageKeys(messages);

    final list = ListView.builder(
      controller: widget.scrollController,
      padding: widget.padding,
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return KeyedSubtree(
          key: _keyForMessage(message.id),
          child: widget.itemBuilder(context, message, index),
        );
      },
    );

    if (!widget.showJumpToBottom) return list;

    return JumpToBottomFabOverlay(
      visible: !_atBottom && messages.isNotEmpty,
      onPressed: _jumpToBottom,
      child: list,
    );
  }
}
