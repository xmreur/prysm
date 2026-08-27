import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/call/group_call_view.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/group_call_manager.dart';
import 'package:prysm/services/call/group_call_snapshot.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/services/call/linux_mic_capture.dart';
import 'package:prysm/ui/core/prysm_linear_progress.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_tabs.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key, required this.child, this.decoyMode = false});

  final Widget child;
  final bool decoyMode;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Contact? _peer;
  String? _loadedPeerOnion;
  String? _lastShownError;
  String? _loadedGroupId;
  String _groupLabel = '';
  final Map<String, String> _memberLabels = {};
  GroupCallManager? _watchedGroupManager;

  @override
  void initState() {
    super.initState();
    if (widget.decoyMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        CallManager.instance.addListener(_onCallChanged);
        _onCallChanged();
      } catch (_) {}
      _ensureGroupListener();
    });
  }

  @override
  void dispose() {
    if (!widget.decoyMode) {
      try {
        CallManager.instance.removeListener(_onCallChanged);
      } catch (_) {}
      _watchedGroupManager?.removeListener(_onGroupCallChanged);
    }
    super.dispose();
  }

  /// The group manager is configured when Tor connects, which can be after
  /// this overlay mounts.
  void _ensureGroupListener() {
    final manager = GroupCallManager.maybeInstance;
    if (manager == null || identical(manager, _watchedGroupManager)) return;
    _watchedGroupManager?.removeListener(_onGroupCallChanged);
    _watchedGroupManager = manager;
    manager.addListener(_onGroupCallChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onGroupCallChanged();
    });
  }

  void _onGroupCallChanged() {
    final manager = GroupCallManager.maybeInstance;
    if (manager == null) return;
    final snapshot = manager.snapshot;

    final error = snapshot.error;
    if (error != null && error != _lastShownError && mounted) {
      _lastShownError = error;
      showPrysmToast(context, error);
    }

    final groupId = snapshot.groupId;
    if (groupId == null) {
      if (_loadedGroupId != null && mounted) {
        setState(() {
          _loadedGroupId = null;
          _groupLabel = '';
          _memberLabels.clear();
        });
      }
      return;
    }
    if (groupId != _loadedGroupId) {
      _loadedGroupId = groupId;
      unawaited(_loadGroup(groupId, snapshot.members));
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadGroup(String groupId, List<String> members) async {
    final group = await DBHelper.getGroupById(groupId);
    final labels = <String, String>{};
    for (final member in members) {
      final row = await DBHelper.getUserById(member);
      final customName = (row?['customName'] as String?)?.trim();
      final name = (row?['name'] as String?)?.trim();
      labels[member] = customName?.isNotEmpty == true
          ? customName!
          : name?.isNotEmpty == true
              ? name!
              : _shortOnion(member);
    }
    if (!mounted || _loadedGroupId != groupId) return;
    setState(() {
      _groupLabel = (group?['name'] as String?)?.trim().isNotEmpty == true
          ? (group!['name'] as String).trim()
          : _shortOnion(groupId);
      _memberLabels
        ..clear()
        ..addAll(labels);
    });
  }

  List<GroupCallParticipant> _participantsFor(GroupCallSnapshot snapshot) {
    final local = LocalOnionAddress.value;
    return [
      for (final member in snapshot.members)
        if (snapshot.joined.contains(member))
          GroupCallParticipant(
            onion: member,
            label: _memberLabels[member] ?? _shortOnion(member),
            muted: member == local
                ? snapshot.localMuted
                : snapshot.peerMuted[member] ?? false,
            isSelf: member == local,
          ),
    ];
  }

  void _onCallChanged() {
    CallManager manager;
    try {
      manager = CallManager.instance;
    } catch (_) {
      return;
    }

    final error = manager.snapshot.error;
    if (error != null && error != _lastShownError && mounted) {
      _lastShownError = error;
      showPrysmToast(context, error);
    }

    final peer = manager.snapshot.peerOnion;
    if (peer == null) {
      if (_peer != null && mounted) {
        setState(() {
          _peer = null;
          _loadedPeerOnion = null;
        });
      }
      return;
    }

    if (peer != _loadedPeerOnion) {
      _loadedPeerOnion = peer;
      unawaited(_loadPeer(peer));
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPeer(String peerOnion) async {
    final row = await DBHelper.getUserById(peerOnion);
    if (!mounted || _loadedPeerOnion != peerOnion) return;

    final contact = row == null
        ? Contact(
            id: peerOnion,
            name: _shortOnion(peerOnion),
            avatarUrl: '',
            identityJson: '',
          )
        : Contact(
            id: row['id'] as String,
            name: (row['name'] as String?)?.trim().isNotEmpty == true
                ? (row['name'] as String).trim()
                : _shortOnion(peerOnion),
            avatarUrl: '',
            avatarBase64: row['avatarBase64'] as String?,
            customName: row['customName'] as String?,
            identityJson: (row['identityJson'] as String?) ?? (row['publicKeyPem'] as String?) ?? '',
          );

    setState(() => _peer = contact);
  }

  String _shortOnion(String onion) {
    if (onion.length <= 16) return onion;
    return '${onion.substring(0, 8)}…${onion.substring(onion.length - 8)}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.decoyMode) return widget.child;

    _ensureGroupListener();
    final groupManager = GroupCallManager.maybeInstance;
    if (groupManager != null && groupManager.snapshot.isInCall) {
      return _buildGroupOverlay(groupManager);
    }

    CallManager? manager;
    try {
      manager = CallManager.instance;
    } catch (_) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: manager,
      builder: (context, child) {
        final snapshot = manager!.snapshot;
        final showOverlay = snapshot.state == CallState.incoming ||
            snapshot.state == CallState.active ||
            snapshot.state == CallState.ringing ||
            snapshot.state == CallState.connecting;

        final peerLabel = _peer?.displayName ??
            snapshot.peerOnion ??
            'Unknown';
        final peerAvatar = _peer?.avatarBase64;

        return Stack(
          children: [
            ?child,
            if (showOverlay)
              Positioned.fill(
                child: ColoredBox(
                  color: context.prysmStyle.tokens.surface,
                  child: SafeArea(
                    child: snapshot.state == CallState.incoming
                        ? _IncomingCallView(
                            peerLabel: peerLabel,
                            peerAvatarBase64: peerAvatar,
                            onAccept: manager.acceptIncoming,
                            onDecline: manager.rejectIncoming,
                          )
                        : _ActiveCallView(
                            peerLabel: peerLabel,
                            peerAvatarBase64: peerAvatar,
                            snapshot: snapshot,
                            onToggleMute: manager.toggleMute,
                            onHangUp: manager.endCall,
                          ),
                  ),
                ),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }

  Widget _buildGroupOverlay(GroupCallManager manager) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, child) {
        final snapshot = manager.snapshot;
        if (!snapshot.isInCall) return child ?? const SizedBox.shrink();
        final label = _groupLabel.isNotEmpty
            ? _groupLabel
            : snapshot.groupId ?? context.l10n.groupCall;
        return Stack(
          children: [
            ?child,
            Positioned.fill(
              child: ColoredBox(
                color: context.prysmStyle.tokens.surface,
                child: SafeArea(
                  child: snapshot.state == CallState.incoming
                      ? GroupIncomingCallView(
                          groupLabel: label,
                          onJoin: () => unawaited(manager.join()),
                          onDismiss: () =>
                              unawaited(manager.dismissIncoming()),
                        )
                      : GroupActiveCallView(
                          groupLabel: label,
                          snapshot: snapshot,
                          participants: _participantsFor(snapshot),
                          onToggleMute: () => unawaited(manager.toggleMute()),
                          onLeave: () => unawaited(manager.leave()),
                        ),
                ),
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _IncomingCallView extends StatelessWidget {
  const _IncomingCallView({
    required this.peerLabel,
    required this.peerAvatarBase64,
    required this.onAccept,
    required this.onDecline,
  });

  final String peerLabel;
  final String? peerAvatarBase64;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ContactAvatar(
              name: peerLabel,
              radius: 56,
              avatarBase64: peerAvatarBase64,
            ),
        const SizedBox(height: 24),
        Text(
          'Incoming call',
          style: context.prysmStyle.headlineStyle,
        ),
        const SizedBox(height: 8),
        Text(peerLabel, style: context.prysmStyle.headlineStyle),
        const SizedBox(height: 48),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PrysmButton(
              label: context.l10n.decline,
              variant: PrysmButtonVariant.danger,
              onPressed: onDecline,
            ),
            const SizedBox(width: 24),
            PrysmButton(
              label: context.l10n.accept,
              onPressed: onAccept,
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}

class _ActiveCallView extends StatefulWidget {
  const _ActiveCallView({
    required this.peerLabel,
    required this.peerAvatarBase64,
    required this.snapshot,
    required this.onToggleMute,
    required this.onHangUp,
  });

  final String peerLabel;
  final String? peerAvatarBase64;
  final CallSnapshot snapshot;
  final VoidCallback onToggleMute;
  final VoidCallback onHangUp;

  @override
  State<_ActiveCallView> createState() => _ActiveCallViewState();
}

class _ActiveCallViewState extends State<_ActiveCallView> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  StreamSubscription<double>? _levelSub;
  double _inputLevel = 0;

  @override
  void initState() {
    super.initState();
    _startTimer();
    if (!kIsWeb && Platform.isLinux) {
      _levelSub = LinuxMicCapture.inputLevel.listen((level) {
        if (!mounted) return;
        setState(() => _inputLevel = level.clamp(0, 1));
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ActiveCallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.activeSince != widget.snapshot.activeSince) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    final since = widget.snapshot.activeSince;
    if (since == null) {
      _elapsed = Duration.zero;
      return;
    }
    _elapsed = DateTime.now().difference(since);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(since);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_levelSub?.cancel());
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _statusLabel(CallState state) {
    switch (state) {
      case CallState.connecting:
        return context.l10n.connecting;
      case CallState.ringing:
        return context.l10n.ringing;
      case CallState.active:
        return _formatElapsed(_elapsed);
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ContactAvatar(
              name: widget.peerLabel,
              radius: 56,
              avatarBase64: widget.peerAvatarBase64,
            ),
        const SizedBox(height: 24),
        Text(
          widget.peerLabel,
          style: context.prysmStyle.headlineStyle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          _statusLabel(widget.snapshot.state),
          style: context.prysmStyle.titleStyle,
        ),
        if (widget.snapshot.peerMuted)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Peer is muted',
              style: context.prysmStyle.bodyStyle,
            ),
          ),
        if (!kIsWeb && Platform.isLinux) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              children: [
                PrysmLinearProgressIndicator(
                  value: widget.snapshot.localMuted ? 0 : _inputLevel,
                ),
                const SizedBox(height: 6),
                Text(
                  widget.snapshot.localMuted ? 'Muted' : 'Microphone level',
                  style: context.prysmStyle.captionStyle,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 48),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PrysmFab(
              icon: widget.snapshot.localMuted
                  ? PrysmIcons.micOff
                  : PrysmIcons.mic,
              onPressed: widget.onToggleMute,
            ),
            const SizedBox(width: 32),
            PrysmFab(
              icon: PrysmIcons.callEnd,
              backgroundColor: context.prysmStyle.tokens.danger,
              onPressed: widget.onHangUp,
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}
