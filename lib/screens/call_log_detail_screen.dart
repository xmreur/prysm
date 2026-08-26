import 'package:flutter/widgets.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/tor_runtime_gate.dart';

String callLogStatusLabel(AppLocalizations l10n, CallLogStatus status) {
  return switch (status) {
    CallLogStatus.completed => l10n.completed,
    CallLogStatus.missed => l10n.missed,
    CallLogStatus.declined => l10n.declined,
    CallLogStatus.failed => l10n.failed,
    CallLogStatus.ringing => l10n.ringing,
  };
}

String formatCallLogDuration(int durationMs) {
  final totalSeconds = durationMs ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
  return '${seconds}s';
}

class CallLogDetailScreen extends StatelessWidget {
  const CallLogDetailScreen({
    required this.log,
    required this.displayName,
    required this.onClose,
    this.avatarBase64,
    super.key,
  });

  final CallLog log;
  final String displayName;
  final String? avatarBase64;
  final VoidCallback onClose;

  String _directionLabel(AppLocalizations l10n) {
    return log.direction == CallLogDirection.inbound
        ? l10n.incoming
        : l10n.outgoing;
  }

  String _actionLabel(AppLocalizations l10n, CallLogPlaceAction action) {
    return switch (action) {
      CallLogPlaceAction.callBack => l10n.callBack,
      CallLogPlaceAction.retry => l10n.retryCall,
    };
  }

  String _formatStartedAt(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final date =
        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  Future<void> _placeCall(BuildContext context) async {
    final l10n = context.l10n;
    void fail(String reason) {
      if (!context.mounted) return;
      showPrysmToast(context, l10n.couldNotStartCallE(reason));
    }

    if (BlockService.instance.isBlocked(log.peerOnion)) {
      fail(l10n.blocked);
      return;
    }
    if (TorRuntimeGate.blocked) {
      fail(l10n.disconnected);
      return;
    }
    try {
      final manager = CallManager.instance;
      if (!TransportProvider.isConfigured) {
        fail(l10n.disconnected);
        return;
      }
      await manager.startCall(log.peerOnion);
    } catch (e) {
      fail('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = context.prysmStyle;
    final action = log.placeAction;

    return PrysmPage(
      title: displayName,
      leading: PrysmIconButton(icon: PrysmIcons.arrowBack, onPressed: onClose),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PrysmTokens.spacing16,
              PrysmTokens.spacing16,
              PrysmTokens.spacing16,
              PrysmTokens.spacing8,
            ),
            child: Row(
              children: [
                ContactAvatar(name: displayName, avatarBase64: avatarBase64),
                const SizedBox(width: PrysmTokens.spacing12),
                Expanded(
                  child: Text(
                    displayName,
                    style: style.titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const PrysmDivider(),
          PrysmListRow(title: _directionLabel(l10n)),
          PrysmListRow(title: callLogStatusLabel(l10n, log.status)),
          PrysmListRow(
            title: l10n.callStarted,
            subtitle: _formatStartedAt(log.startedAt),
          ),
          if (log.durationMs > 0)
            PrysmListRow(
              title: l10n.callDuration,
              subtitle: formatCallLogDuration(log.durationMs),
            ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.all(PrysmTokens.spacing16),
              child: PrysmButton(
                label: _actionLabel(l10n, action),
                onPressed: () => _placeCall(context),
              ),
            ),
        ],
      ),
    );
  }
}
