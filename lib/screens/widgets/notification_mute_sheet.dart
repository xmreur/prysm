import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

String _formatClock(DateTime dt) {
  final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

String _formatDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[dt.month - 1]} ${dt.day}';
}

String formatMuteSubtitle(MuteInfo? info) {
  if (info == null) {
    return 'Silence message alerts';
  }
  if (info.isForever) {
    return 'Muted until you turn notifications back on';
  }
  final expiresAt = info.expiresAt!;
  final time = _formatClock(expiresAt);
  final today = DateTime.now();
  final isToday = expiresAt.year == today.year &&
      expiresAt.month == today.month &&
      expiresAt.day == today.day;
  if (isToday) {
    return 'Muted until $time';
  }
  return 'Muted until ${_formatDate(expiresAt)}, $time';
}

Future<void> showNotificationMuteSheet({
  required BuildContext context,
  required MuteTarget target,
  required String id,
  required String label,
  VoidCallback? onChanged,
}) async {
  final service = NotificationMuteService.instance;
  final info = service.muteInfo(target, id);
  final isMuted = info != null;

  await showPrysmSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                isMuted ? 'Notifications muted' : 'Mute notifications',
                style: ctx.prysmStyle.titleStyle,
              ),
            ),
            if (isMuted)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  formatMuteSubtitle(info),
                  style: ctx.prysmStyle.captionStyle,
                ),
              ),
            if (isMuted)
              PrysmListRow(
                leading: const Icon(PrysmIcons.notificationsActiveOutlined),
                title: 'Turn notifications back on',
                onTap: () async {
                  await service.unmute(target, id);
                  if (ctx.mounted) Navigator.pop(ctx);
                  onChanged?.call();
                  if (context.mounted) {
                    showPrysmToast(context, 'Notifications enabled for $label');
                  }
                },
              ),
            if (isMuted) const PrysmDivider(),
            ...MuteDuration.values.map((duration) {
              return PrysmListRow(
                leading: Icon(
                  duration == MuteDuration.forever
                      ? PrysmIcons.notificationsOffOutlined
                      : PrysmIcons.scheduleOutlined,
                ),
                title: duration.label,
                onTap: () async {
                  await service.mute(target, id, duration);
                  if (ctx.mounted) Navigator.pop(ctx);
                  onChanged?.call();
                  if (context.mounted) {
                    final mutedUntil = duration == MuteDuration.forever
                        ? 'until you turn them back on'
                        : 'for ${duration.label}';
                    showPrysmToast(context, 'Notifications muted $mutedUntil for $label');
                  }
                },
              );
            }),
          ],
        ),
      ),
    ),
  );
}
