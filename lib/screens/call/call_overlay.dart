import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/services/call/linux_mic_capture.dart';

class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Contact? _peer;
  String? _loadedPeerOnion;
  String? _lastShownError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        CallManager.instance.addListener(_onCallChanged);
        _onCallChanged();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    try {
      CallManager.instance.removeListener(_onCallChanged);
    } catch (_) {}
    super.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }

    final peer = manager.snapshot.peerOnion;
    if (peer == null) {
      if (_peer != null) {
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
    setState(() {});
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
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
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
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(peerLabel, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 48),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton.extended(
              heroTag: 'decline_call',
              backgroundColor: Colors.red,
              onPressed: onDecline,
              icon: const Icon(Icons.call_end),
              label: const Text('Decline'),
            ),
            const SizedBox(width: 24),
            FloatingActionButton.extended(
              heroTag: 'accept_call',
              backgroundColor: Colors.green,
              onPressed: onAccept,
              icon: const Icon(Icons.call),
              label: const Text('Accept'),
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
        return 'Connecting...';
      case CallState.ringing:
        return 'Ringing...';
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
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          _statusLabel(widget.snapshot.state),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (widget.snapshot.peerMuted)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Peer is muted',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (!kIsWeb && Platform.isLinux) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: widget.snapshot.localMuted ? 0 : _inputLevel,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.snapshot.localMuted ? 'Muted' : 'Microphone level',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 48),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton(
              heroTag: 'mute_call',
              onPressed: widget.onToggleMute,
              child: Icon(
                widget.snapshot.localMuted ? Icons.mic_off : Icons.mic,
              ),
            ),
            const SizedBox(width: 32),
            FloatingActionButton(
              heroTag: 'hangup_call',
              backgroundColor: Colors.red,
              onPressed: widget.onHangUp,
              child: const Icon(Icons.call_end),
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}
