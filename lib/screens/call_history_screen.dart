import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/services/call/call_logs_service.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/onion_id_codec.dart';

class CallHistoryScreen extends StatefulWidget {
  final VoidCallback onClose;

  const CallHistoryScreen({
    required this.onClose,
    super.key,
  });

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  final List<CallLog> _logs = [];
  final Map<String, Map<String, dynamic>?> _users = {};
  bool _loading = true;
  StreamSubscription<void>? _subscription;

  @override
  void initState() {
    super.initState();
    _load();
    _subscription = CallLogsService.instance.onChanged.listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final logs = await CallLogsService.instance.getLogs(limit: 200);
    final uniquePeerIds = logs.map((log) => log.peerOnion).toSet();
    final userFutures = <Future<MapEntry<String, Map<String, dynamic>?>>>[];
    for (final peerOnion in uniquePeerIds) {
      userFutures.add(() async {
        final user = await DBHelper.getUserById(peerOnion);
        return MapEntry(peerOnion, user);
      }());
    }
    final users = Map<String, Map<String, dynamic>?>.fromEntries(
      await Future.wait(userFutures),
    );
    if (!mounted) return;
    setState(() {
      _logs
        ..clear()
        ..addAll(logs);
      _users
        ..clear()
        ..addAll(users);
      _loading = false;
    });
  }

  String _displayName(String peerOnion) {
    final user = _users[peerOnion];
    if (user != null) {
      final customName = user['customName'] as String?;
      final name = user['name'] as String?;
      if (customName != null && customName.isNotEmpty) return customName;
      if (name != null && name.isNotEmpty) return name;
    }
    try {
      final encoded = encodeOnionToBase58(peerOnion);
      if (encoded.length <= 16) return encoded;
      return '${encoded.substring(0, 6)}…${encoded.substring(encoded.length - 4)}';
    } catch (_) {
      if (peerOnion.length <= 16) return peerOnion;
      return '${peerOnion.substring(0, 6)}…';
    }
  }

  String _statusLabel(CallLogStatus status) {
    return switch (status) {
      CallLogStatus.completed => 'Completed',
      CallLogStatus.missed => 'Missed',
      CallLogStatus.declined => 'Declined',
      CallLogStatus.failed => 'Failed',
      CallLogStatus.ringing => 'Ringing',
    };
  }

  IconData _statusIcon(CallLogStatus status) {
    return switch (status) {
      CallLogStatus.completed => PrysmIcons.call,
      CallLogStatus.missed => PrysmIcons.callEnd,
      CallLogStatus.declined => PrysmIcons.callEnd,
      CallLogStatus.failed => PrysmIcons.callEnd,
      CallLogStatus.ringing => PrysmIcons.call,
    };
  }

  Color _statusColor(CallLogStatus status) {
    final tokens = context.prysmStyle.tokens;
    return switch (status) {
      CallLogStatus.completed => const Color(0xFF4CAF50),
      CallLogStatus.missed => tokens.danger,
      CallLogStatus.declined => tokens.textMuted,
      CallLogStatus.failed => tokens.danger,
      CallLogStatus.ringing => tokens.accent,
    };
  }

  String _formatDuration(int durationMs) {
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

  String _formatDate(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    final isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isSameDay) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year % 100}';
  }

  Future<void> _confirmClear() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Clear call history',
      content: const Text('This will permanently delete all call logs.'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Clear',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;
    await CallLogsService.instance.deleteAllLogs();
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      title: 'Call History',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      actions: [
        if (_logs.isNotEmpty)
          PrysmIconButton(
            icon: PrysmIcons.deleteOutline,
            tooltip: 'Clear history',
            onPressed: _confirmClear,
          ),
      ],
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : _logs.isEmpty
              ? Center(
                  child: Text(
                    'No calls yet',
                    style: TextStyle(
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _logs.length,
                  separatorBuilder: (_, _) => const PrysmDivider(),
                  itemBuilder: (context, index) {
                    final log = _logs[index];
                    final statusColor = _statusColor(log.status);
                    final subtitle = log.status == CallLogStatus.completed
                        ? '${_formatDuration(log.durationMs)} · ${_formatDate(log.startedAt)}'
                        : '${_statusLabel(log.status)} · ${_formatDate(log.startedAt)}';
                    return PrysmListRow(
                      leading: ContactAvatar(
                        name: _displayName(log.peerOnion),
                        avatarBase64: _users[log.peerOnion]?['avatarBase64'] as String?,
                      ),
                      title: _displayName(log.peerOnion),
                      subtitle: subtitle,
                      trailing: Icon(
                        _statusIcon(log.status),
                        color: statusColor,
                      ),
                    );
                  },
                ),
    );
  }
}
