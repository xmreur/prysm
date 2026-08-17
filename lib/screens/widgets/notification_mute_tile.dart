import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/screens/widgets/notification_mute_sheet.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class NotificationMuteTile extends StatefulWidget {
  final MuteTarget target;
  final String id;
  final String label;

  const NotificationMuteTile({
    required this.target,
    required this.id,
    required this.label,
    super.key,
  });

  @override
  State<NotificationMuteTile> createState() => _NotificationMuteTileState();
}

class _NotificationMuteTileState extends State<NotificationMuteTile> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final info = NotificationMuteService.instance.muteInfo(widget.target, widget.id);
    final isMuted = info != null;

    return PrysmListRow(
      leading: Icon(
        isMuted ? PrysmIcons.notificationsOffOutlined : PrysmIcons.notificationsOutlined,
      ),
      title: isMuted
          ? context.l10n.notificationsMuted
          : context.l10n.muteNotifications,
      subtitle: formatMuteSubtitle(info, context.l10n),
      trailing: const Icon(PrysmIcons.chevronRight),
      onTap: () => showNotificationMuteSheet(
        context: context,
        target: widget.target,
        id: widget.id,
        label: widget.label,
        onChanged: _refresh,
      ),
    );
  }
}
