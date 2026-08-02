import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/models/disappearing_timer.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/util/disappearing_timer_refresh_notifier.dart';
import 'package:prysm/util/key_manager.dart';

/// Settings row to enable or change per-conversation disappearing messages.
class DisappearingMessagesTile extends StatefulWidget {
  const DisappearingMessagesTile({
    required this.conversationId,
    required this.userId,
    required this.keyManager,
    this.isGroup = false,
    this.groupService,
    this.memberIds = const [],
    super.key,
  });

  final String conversationId;
  final String userId;
  final KeyManager keyManager;
  final bool isGroup;
  final GroupService? groupService;
  final List<String> memberIds;

  @override
  State<DisappearingMessagesTile> createState() =>
      _DisappearingMessagesTileState();
}

class _DisappearingMessagesTileState extends State<DisappearingMessagesTile> {
  int? _timerSeconds;
  bool _loaded = false;
  StreamSubscription<String>? _refreshSub;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshSub =
        DisappearingTimerRefreshNotifier.instance.onChanged.listen((id) {
      if (id == widget.conversationId) _load();
    });
  }

  @override
  void dispose() {
    _refreshSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final seconds =
        await DisappearingTimerService.getTimerSeconds(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _timerSeconds = seconds;
      _loaded = true;
    });
  }

  Future<void> _pickTimer() async {
    final selected = await showPrysmSheet<int?>(
      context: context,
      builder: (ctx) => _TimerPickerSheet(currentSeconds: _timerSeconds),
    );
    if (selected == _timerSeconds) return;

    final service = DisappearingTimerService(
      userId: widget.userId,
      keyManager: widget.keyManager,
    );
    if (widget.isGroup) {
      await service.setGroupTimer(
        groupId: widget.conversationId,
        memberIds: widget.memberIds,
        timerSeconds: selected,
        groupService: widget.groupService,
      );
    } else {
      await service.setDirectTimer(
        peerId: widget.conversationId,
        timerSeconds: selected,
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();

    final subtitle = DisappearingTimerPresets.labelForSeconds(_timerSeconds);
    return PrysmListRow(
      leading: const Icon(PrysmIcons.timer),
      title: 'Disappearing messages',
      subtitle: subtitle,
      onTap: _pickTimer,
    );
  }
}

class _TimerPickerSheet extends StatelessWidget {
  const _TimerPickerSheet({required this.currentSeconds});

  final int? currentSeconds;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Disappearing messages', style: style.titleStyle),
          ),
          PrysmListRow(
            title: 'Off',
            trailing: currentSeconds == null ? const Icon(PrysmIcons.check) : null,
            onTap: () => Navigator.pop(context, null),
          ),
          for (final preset in DisappearingTimerPresets.all)
            PrysmListRow(
              title: preset.label,
              trailing: currentSeconds == preset.seconds
                  ? const Icon(PrysmIcons.check)
                  : null,
              onTap: () => Navigator.pop(context, preset.seconds),
            ),
        ],
      ),
    );
  }
}

/// Avatar with an optional Telegram-style disappearing-timer badge.
class DisappearingTimerAvatar extends StatelessWidget {
  const DisappearingTimerAvatar({
    required this.name,
    this.radius = 20,
    this.avatarBase64,
    this.timerSeconds,
    super.key,
  });

  final String name;
  final double radius;
  final String? avatarBase64;
  final int? timerSeconds;

  @override
  Widget build(BuildContext context) {
    final avatar = ContactAvatar(
      name: name,
      radius: radius,
      avatarBase64: avatarBase64,
    );
    if (timerSeconds == null || timerSeconds! <= 0) return avatar;

    final tokens = context.prysmStyle.tokens;
    final badgeSize = (radius * 1.45).clamp(18.0, 22.0);
    final label = DisappearingTimerPresets.shortLabelForSeconds(timerSeconds);

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: _DisappearingTimerBadge(
              size: badgeSize,
              label: label,
              backgroundColor: tokens.brightness == Brightness.dark
                  ? const Color(0xFF2B2B2B)
                  : const Color(0xE6FFFFFF),
              borderColor: tokens.brightness == Brightness.dark
                  ? const Color(0xFFB8B8B8)
                  : const Color(0xFF8A8A8A),
              textColor: tokens.brightness == Brightness.dark
                  ? const Color(0xFFF2F2F2)
                  : const Color(0xFF3A3A3A),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisappearingTimerBadge extends StatelessWidget {
  const _DisappearingTimerBadge({
    required this.size,
    required this.label,
    required this.backgroundColor,
    required this.borderColor,
    required this.textColor,
  });

  final double size;
  final String label;
  final Color backgroundColor;
  final Color borderColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = label.length > 2 ? size * 0.28 : size * 0.34;
    return CustomPaint(
      painter: _DashedCirclePainter(
        color: borderColor,
        strokeWidth: 1.2,
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({
    required this.color,
    this.strokeWidth = 1.2,
  });

  final Color color;
  final double strokeWidth;
  static const double _dashLength = 2.5;
  static const double _gapLength = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final radius = size.shortestSide / 2 - strokeWidth;
    final center = Offset(size.width / 2, size.height / 2);
    final circumference = 2 * math.pi * radius;
    final segment = _dashLength + _gapLength;
    final dashCount = (circumference / segment).floor().clamp(8, 24);
    final sweepPerDash = (_dashLength / circumference) * 2 * math.pi;
    final sweepPerGap = (_gapLength / circumference) * 2 * math.pi;

    var startAngle = -math.pi / 2;
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepPerDash,
        false,
        paint,
      );
      startAngle += sweepPerDash + sweepPerGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

String disappearingTimerNoticeLabel({
  required int? timerSeconds,
  required String actorId,
  required String localUserId,
  required String? actorDisplayName,
}) {
  final who = actorId == localUserId
      ? 'You'
      : (actorDisplayName?.isNotEmpty == true ? actorDisplayName! : 'Someone');
  if (timerSeconds == null || timerSeconds <= 0) {
    return '$who turned off disappearing messages';
  }
  return '$who set messages to disappear in '
      '${DisappearingTimerPresets.labelForSeconds(timerSeconds).toLowerCase()}';
}

bool isDisappearingTimerNoticeRow(Map<String, dynamic> row) =>
    row['type'] == disappearingTimerNoticeType;
