import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/util/schedule_time_format.dart';

String formatMuteSubtitle(MuteInfo? info, AppLocalizations l10n) {
  if (info == null) {
    return l10n.silenceMessageAlerts;
  }
  if (info.isForever) {
    return l10n.mutedUntilYouTurnNotificationsBackOn;
  }
  final expiresAt = info.expiresAt!;
  final time = formatScheduleClock(expiresAt);
  final today = DateTime.now();
  final isToday = expiresAt.year == today.year &&
      expiresAt.month == today.month &&
      expiresAt.day == today.day;
  if (isToday) {
    return l10n.mutedUntilTime(time);
  }
  return l10n.mutedUntilDateAndTime(formatScheduleDate(expiresAt), time);
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
                isMuted
                    ? ctx.l10n.notificationsMuted
                    : ctx.l10n.muteNotifications,
                style: ctx.prysmStyle.titleStyle,
              ),
            ),
            if (isMuted)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  formatMuteSubtitle(info, ctx.l10n),
                  style: ctx.prysmStyle.captionStyle,
                ),
              ),
            if (isMuted)
              PrysmListRow(
                leading: const Icon(PrysmIcons.notificationsActiveOutlined),
                title: ctx.l10n.turnNotificationsBackOn,
                onTap: () async {
                  await service.unmute(target, id);
                  if (ctx.mounted) Navigator.pop(ctx);
                  onChanged?.call();
                  if (context.mounted) {
                    showPrysmToast(
                      context,
                      context.l10n.notificationsEnabledForLabel(label),
                    );
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
                        ? context.l10n.untilYouTurnThemBackOn
                        : context.l10n.mutedForDuration(duration.label);
                    showPrysmToast(
                      context,
                      context.l10n.notificationsMutedMuteduntilForLabel(
                        mutedUntil,
                        label,
                      ),
                    );
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
