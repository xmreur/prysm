import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';

import 'package:prysm/models/contact.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/onion_id_codec.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

class BlockedContactsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final void Function(String peerId)? onOpenChat;

  const BlockedContactsScreen({
    required this.onClose,
    this.onOpenChat,
    super.key,
  });

  @override
  State<BlockedContactsScreen> createState() => _BlockedContactsScreenState();
}

class _BlockedContactsScreenState extends State<BlockedContactsScreen> {
  final Map<String, Contact> _contactsById = {};
  List<String> _blockedIds = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final blockedIds = BlockService.instance.blockedIds.toList()
      ..sort((a, b) {
        final aAt = BlockService.instance.blockedAt(a) ?? 0;
        final bAt = BlockService.instance.blockedAt(b) ?? 0;
        return bAt.compareTo(aAt);
      });

    final contacts = <String, Contact>{};
    for (final peerId in blockedIds) {
      final user = await DBHelper.getUserById(peerId);
      if (user != null) {
        contacts[peerId] = Contact(
          id: peerId,
          name: (user['name'] as String?) ?? peerId,
          avatarUrl: '',
          avatarBase64: user['avatarBase64'] as String?,
          customName: user['customName'] as String?,
          identityJson: (user['identityJson'] as String?) ??
              (user['publicKeyPem'] as String?) ??
              '',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _blockedIds = blockedIds;
      _contactsById
        ..clear()
        ..addAll(contacts);
      _loading = false;
    });
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

  Future<void> _confirmUnblock(String peerId) async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Unblock contact',
      content: const Text(
        'This contact will be able to message and call you again.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Unblock',
    );
    if (confirmed != true || !mounted) return;

    await BlockService.instance.unblock(peerId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      title: 'Blocked contacts',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : _blockedIds.isEmpty
              ? Center(
                  child: Text(
                    'No blocked contacts',
                    style: TextStyle(
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _blockedIds.length,
                  separatorBuilder: (context, index) => const PrysmDivider(),
                  itemBuilder: (context, index) {
                    final peerId = _blockedIds[index];
                    final contact = _contactsById[peerId];
                    final displayName =
                        contact?.displayName ?? _shortOnion(peerId);

                    return PrysmListRow(
                      leading: ContactAvatar(
                        name: displayName,
                        avatarBase64: contact?.avatarBase64,
                      ),
                      title: displayName,
                      subtitleWidget: Text(
                        _shortOnion(peerId),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      trailing: PrysmTextButton(
                        label: 'Unblock',
                        onPressed: () => _confirmUnblock(peerId),
                      ),
                      onTap: () {
                        if (contact == null || widget.onOpenChat == null) {
                          return;
                        }
                        widget.onOpenChat!(peerId);
                      },
                    );
                  },
                ),
    );
  }
}
