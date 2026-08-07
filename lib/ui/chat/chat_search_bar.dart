import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/message_search_hit.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/prysm_search_field.dart';

class ChatSearchBar extends StatefulWidget {
  const ChatSearchBar({
    required this.conversationId,
    required this.onResultSelected,
    required this.onClose,
    this.onQueryChanged,
    super.key,
  });

  final String conversationId;
  final void Function(MessageSearchHit hit, int index) onResultSelected;
  final VoidCallback onClose;
  final ValueChanged<String>? onQueryChanged;

  @override
  State<ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<ChatSearchBar> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<MessageSearchHit> _results = const [];
  int _currentIndex = 0;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    setState(() => _query = trimmed);
    widget.onQueryChanged?.call(trimmed);
    if (trimmed.length < 2) {
      setState(() {
        _results = const [];
        _currentIndex = 0;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final hits = await MessagesDb.searchMessagesInConversation(
        widget.conversationId,
        trimmed,
      );
      if (!mounted) return;
      setState(() {
        _results = hits;
        _currentIndex = hits.isEmpty ? 0 : hits.length - 1;
      });
      if (hits.isNotEmpty) {
        widget.onResultSelected(hits[_currentIndex], _currentIndex);
      }
    });
  }

  void _step(int delta) {
    if (_results.isEmpty) return;
    final next = (_currentIndex + delta).clamp(0, _results.length - 1);
    setState(() => _currentIndex = next);
    widget.onResultSelected(_results[next], next);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final counter = _results.isEmpty
        ? ''
        : '${_currentIndex + 1}/${_results.length}';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: tokens.divider.withValues(alpha: 0.15)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: PrysmSearchField(
              controller: _controller,
              hintText: 'Search in chat...',
              onChanged: _onQueryChanged,
              onClear: () {
                _controller.clear();
                _onQueryChanged('');
              },
            ),
          ),
          if (_query.length >= 2) ...[
            const SizedBox(width: 8),
            Text(counter, style: TextStyle(color: tokens.textMuted, fontSize: 13)),
            PrysmIconButton(
              icon: CupertinoIcons.chevron_up,
              tooltip: 'Previous match',
              onPressed: _results.isEmpty ? null : () => _step(-1),
            ),
            PrysmIconButton(
              icon: PrysmIcons.chevronDown,
              tooltip: 'Next match',
              onPressed: _results.isEmpty ? null : () => _step(1),
            ),
          ],
          PrysmIconButton(
            icon: PrysmIcons.close,
            tooltip: 'Close search',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}
