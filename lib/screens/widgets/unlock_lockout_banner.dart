import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';

import 'package:prysm/services/unlock_lockout_service.dart';

String formatLockoutDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '${minutes}m';
  }
  return '${duration.inSeconds}s';
}

/// Polls [UnlockLockoutService] and shows lockout / attempts-remaining copy.
class UnlockLockoutStatus extends StatefulWidget {
  const UnlockLockoutStatus({
    required this.showAttemptsRemaining,
    this.lastFailure = false,
    super.key,
  });

  final bool showAttemptsRemaining;
  final bool lastFailure;

  @override
  State<UnlockLockoutStatus> createState() => UnlockLockoutStatusState();
}

class UnlockLockoutStatusState extends State<UnlockLockoutStatus> {
  final _lockout = UnlockLockoutService.instance;
  Timer? _timer;
  bool _lockedOut = false;
  Duration? _remaining;
  int _attemptsRemaining = UnlockLockoutService.maxAttempts;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void didUpdateWidget(UnlockLockoutStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lastFailure != oldWidget.lastFailure) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final locked = await _lockout.isLockedOut();
    final remaining = locked ? await _lockout.remainingLockout() : null;
    final attempts = await _lockout.attemptsRemaining();
    if (!mounted) return;
    setState(() {
      _lockedOut = locked;
      _remaining = remaining;
      _attemptsRemaining = attempts;
    });
  }

  bool get isLockedOut => _lockedOut;

  @override
  Widget build(BuildContext context) {
    if (_lockedOut && _remaining != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          'Too many attempts. Try again in ${formatLockoutDuration(_remaining!)}.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.prysmStyle.tokens.danger),
        ),
      );
    }
    if (widget.showAttemptsRemaining &&
        widget.lastFailure &&
        _attemptsRemaining > 0 &&
        _attemptsRemaining < UnlockLockoutService.maxAttempts) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          '$_attemptsRemaining attempt${_attemptsRemaining == 1 ? '' : 's'} remaining',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.prysmStyle.tokens.textPrimary.withAlpha(180),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
