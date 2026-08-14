import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/services/group_invite_promoter.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/onion_id_codec.dart';

/// Group invites received from senders who are not in the local contacts.
///
/// Only the sender's address and the arrival time are shown: the invite
/// itself is still encrypted and unauthenticated, so nothing inside it —
/// group name, avatar, roster — may be displayed. Accepting adds the contact
/// (the only network call in this flow, and it is the user's own action) and
/// then replays the invite through the authenticated path.
class InviteRequestsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final String onionAddress;
  final KeyManager keyManager;
  final VoidCallback? onChanged;

  const InviteRequestsScreen({
    required this.onClose,
    required this.onionAddress,
    required this.keyManager,
    this.onChanged,
    super.key,
  });

  @override
  State<InviteRequestsScreen> createState() => _InviteRequestsScreenState();
}

class _InviteRequestsScreenState extends State<InviteRequestsScreen> {
  List<Map<String, Object?>> _rows = const [];
  bool _loading = true;
  String? _busySenderId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await GroupPendingInviteStore.pending();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // Without this the screen keeps the progress indicator forever and the
      // exception escapes the unawaited future in initState.
      Logging.error('Reading the pending invites failed: $e',
          'InviteRequestsScreen');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read the pending requests.';
      });
    }
    widget.onChanged?.call();
  }

  String _shortOnion(String onion) {
    try {
      final encoded = encodeOnionToBase58(onion);
      if (encoded.length <= 12) return encoded;
      return '${encoded.substring(0, 6)}…${encoded.substring(encoded.length - 4)}';
    } catch (_) {
      if (onion.length <= 12) return onion;
      return '${onion.substring(0, 6)}…';
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  String _receivedLabel(int receivedAt) {
    final at = DateTime.fromMillisecondsSinceEpoch(receivedAt);
    return '${at.year}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}';
  }

  Future<void> _accept(String senderId) async {
    if (_busySenderId != null) return;
    setState(() => _busySenderId = senderId);
    String? failTitle;
    String? failBody;
    try {
      final result = await ContactAddService.instance.addContact(
        onionId: senderId,
        displayName: '',
      );
      if (result != ContactAddResult.success) {
        failTitle = 'Could not reach this contact';
        failBody = 'The invite is still waiting. '
            'Try again when they are online.';
      } else {
        final joined = await GroupInvitePromoter(
          userId: widget.onionAddress,
          keyManager: widget.keyManager,
        ).promote(senderId);
        if (!joined) {
          // promote() consumes the row either way — an envelope that fails to
          // authenticate is garbage and retrying it forever is worse. Say so,
          // or the request just disappears with no group to show for it and
          // the contact silently added.
          failTitle = 'Could not join the group';
          failBody = 'The contact was added, but this invite could not be '
              'applied and has been removed. Ask them to invite you again.';
        }
      }
    } catch (e) {
      Logging.error(
        'Accepting the invite from ${Logging.redactOnion(senderId)} failed: $e',
        'InviteRequestsScreen',
      );
      failTitle = 'Could not join the group';
      failBody = 'Something went wrong while accepting this invite.';
    } finally {
      if (mounted) setState(() => _busySenderId = null);
    }
    // Always reload: the row may be gone whether or not the join succeeded.
    await _load();
    if (!mounted || failTitle == null) return;
    await showPrysmDialog<void>(
      context: context,
      title: failTitle,
      content: Text(failBody!),
      confirmLabel: 'OK',
      onConfirm: () => Navigator.of(context).pop(),
    );
  }

  Future<void> _discard(String senderId) async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Discard invite',
      content: const Text('This request will be removed.'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Discard',
    );
    if (confirmed != true) return;
    await GroupPendingInviteStore.discard(senderId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      title: 'Invite requests',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                )
              : _rows.isEmpty
              ? Center(
                  child: Text(
                    'No invite requests',
                    style: TextStyle(
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _rows.length,
                  separatorBuilder: (context, index) => const PrysmDivider(),
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final senderId = row['senderId'] as String;
                    final short = _shortOnion(senderId);
                    final busy = _busySenderId == senderId;
                    // Every row is locked while any accept runs, not just the
                    // busy one: _busySenderId holds a single sender, so a
                    // second tap would steal it, drop the first row's spinner
                    // and leave two accept flows racing the same store.
                    final locked = _busySenderId != null;

                    return PrysmListRow(
                      leading: ContactAvatar(name: short, avatarBase64: null),
                      title: short,
                      subtitleWidget: Text(
                        'Group invite · ${_receivedLabel(row['receivedAt'] as int)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: busy
                          ? const PrysmProgressIndicator()
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PrysmTextButton(
                                  label: 'Discard',
                                  onPressed:
                                      locked ? null : () => _discard(senderId),
                                ),
                                PrysmTextButton(
                                  label: 'Add contact and join',
                                  onPressed:
                                      locked ? null : () => _accept(senderId),
                                ),
                              ],
                            ),
                    );
                  },
                ),
    );
  }
}
