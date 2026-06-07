import 'package:flutter/material.dart';
import 'package:prysm/screens/widgets/notification_mute_sheet.dart';
import 'package:prysm/services/notification_mute_service.dart';

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

    return ListTile(
      leading: Icon(
        isMuted ? Icons.notifications_off_outlined : Icons.notifications_outlined,
      ),
      title: Text(isMuted ? 'Notifications muted' : 'Mute notifications'),
      subtitle: Text(formatMuteSubtitle(info)),
      trailing: const Icon(Icons.chevron_right),
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
