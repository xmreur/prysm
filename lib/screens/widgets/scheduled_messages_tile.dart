import 'package:flutter/widgets.dart';
import 'package:prysm/models/scheduled_message.dart';
import 'package:prysm/services/scheduled_message_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/schedule_time_format.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

/// Settings row listing the conversation's scheduled messages, with a sheet to
/// cancel them. Hidden entirely when nothing is queued.
class ScheduledMessagesTile extends StatefulWidget {
  const ScheduledMessagesTile({
    required this.userId,
    required this.keyManager,
    required this.conversationId,
    super.key,
  });

  final String userId;
  final KeyManager keyManager;
  final String conversationId;

  @override
  State<ScheduledMessagesTile> createState() => _ScheduledMessagesTileState();
}

class _ScheduledMessagesTileState extends State<ScheduledMessagesTile> {
  late final ScheduledMessageService _service;
  List<ScheduledMessage> _pending = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _service = ScheduledMessageService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    _load();
  }

  Future<void> _load() async {
    final pending = await _service.pendingFor(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _loaded = true;
    });
  }

  Future<void> _cancel(ScheduledMessage message) async {
    await _service.cancel(message.id);
    if (!mounted) return;
    showPrysmToast(context, context.l10n.scheduledMessageCancelled);
    await _load();
  }

  Future<void> _openList() async {
    await showPrysmSheet<void>(
      context: context,
      builder: (ctx) => _ScheduledListSheet(
        messages: _pending,
        onCancel: (message) async {
          Navigator.pop(ctx);
          await _cancel(message);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _pending.isEmpty) return const SizedBox.shrink();

    final next = _pending.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrysmListRow(
          leading: const Icon(PrysmIcons.accessTime),
          title: _pending.length == 1
              ? '1 scheduled message'
              : '${_pending.length} scheduled messages',
          subtitle: context.l10n.nextScheduleLabel(formatScheduleLabel(next.sendAt)),
          trailing: const Icon(PrysmIcons.chevronRight),
          onTap: _openList,
        ),
        const PrysmDivider(),
      ],
    );
  }
}

class _ScheduledListSheet extends StatelessWidget {
  const _ScheduledListSheet({required this.messages, required this.onCancel});

  final List<ScheduledMessage> messages;
  final Future<void> Function(ScheduledMessage message) onCancel;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PrysmTokens.spacing20,
            PrysmTokens.spacing8,
            PrysmTokens.spacing20,
            PrysmTokens.spacing12,
          ),
          child: Text(context.l10n.scheduledMessages, style: style.titleStyle),
        ),
        const PrysmDivider(),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: messages.length,
            separatorBuilder: (_, _) => const PrysmDivider(),
            itemBuilder: (ctx, index) {
              final message = messages[index];
              return PrysmListRow(
                title: formatScheduleLabel(message.sendAt),
                subtitle: message.body,
                trailing: PrysmTextButton(
                  label: context.l10n.cancel,
                  color: style.tokens.danger,
                  onPressed: () async {
                    final confirmed = await showPrysmConfirmDialog(
                      context: ctx,
                      title: context.l10n.cancelScheduledMessage,
                      content: Text(context.l10n.itWillNotBeSent,
                        style: style.bodyStyle,
                      ),
                      confirmLabel: context.l10n.cancelMessage,
                      cancelLabel: context.l10n.keep,
                    );
                    if (confirmed == true) await onCancel(message);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
