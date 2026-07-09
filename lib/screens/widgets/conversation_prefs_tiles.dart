import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/services/conversation_preferences_service.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';

class ConversationPrefsTiles extends StatefulWidget {
  final String conversationId;
  final VoidCallback onChanged;
  final VoidCallback? onArchived;

  const ConversationPrefsTiles({
    required this.conversationId,
    required this.onChanged,
    this.onArchived,
    super.key,
  });

  @override
  State<ConversationPrefsTiles> createState() => _ConversationPrefsTilesState();
}

class _ConversationPrefsTilesState extends State<ConversationPrefsTiles> {
  ConversationPreferences? _prefs;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await ConversationPreferencesService.instance.getAll();
    if (!mounted) return;
    setState(() {
      _prefs = all[widget.conversationId];
      _loading = false;
    });
  }

  Future<void> _togglePin() async {
    if (_prefs?.isPinned == true) {
      await ConversationPreferencesService.instance.unpin(widget.conversationId);
    } else {
      await ConversationPreferencesService.instance.pin(widget.conversationId);
    }
    await _load();
    widget.onChanged();
  }

  Future<void> _toggleArchive() async {
    if (_prefs?.isArchived == true) {
      await ConversationPreferencesService.instance.unarchive(widget.conversationId);
      await _load();
      widget.onChanged();
      return;
    }
    await ConversationPreferencesService.instance.archive(widget.conversationId);
    widget.onArchived?.call();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 96,
        child: Center(child: PrysmProgressIndicator()),
      );
    }

    final isPinned = _prefs?.isPinned ?? false;
    final isArchived = _prefs?.isArchived ?? false;

    return Column(
      children: [
        PrysmListRow(
          leading: Icon(isPinned ? PrysmIcons.pushPinOutlined : PrysmIcons.pushPin),
          title: isPinned ? 'Unpin chat' : 'Pin chat',
          onTap: _togglePin,
        ),
        PrysmListRow(
          leading: const Icon(PrysmIcons.archive),
          title: isArchived ? 'Unarchive chat' : 'Archive chat',
          onTap: _toggleArchive,
        ),
      ],
    );
  }
}
