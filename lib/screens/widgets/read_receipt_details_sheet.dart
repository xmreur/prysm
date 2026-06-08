import 'package:flutter/material.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/util/db_helper.dart';

class ReadReceiptMember {
  final String memberId;
  final String displayName;
  final int? readAt;
  final bool isPending;

  const ReadReceiptMember({
    required this.memberId,
    required this.displayName,
    this.readAt,
    this.isPending = false,
  });
}

class ReadReceiptDetailsSheet extends StatelessWidget {
  final String messageId;
  final String? groupId;
  final String localUserId;
  final String? messageAuthorId;
  final List<String>? groupMemberIds;
  final String? directPeerId;
  final String deliveryStatusLabel;
  final bool showReadSection;

  const ReadReceiptDetailsSheet({
    required this.messageId,
    required this.localUserId,
    required this.deliveryStatusLabel,
    this.groupId,
    this.messageAuthorId,
    this.groupMemberIds,
    this.directPeerId,
    this.showReadSection = true,
    super.key,
  });

  static Future<void> show(
    BuildContext context, {
    required String messageId,
    required String localUserId,
    required String deliveryStatusLabel,
    String? groupId,
    String? messageAuthorId,
    List<String>? groupMemberIds,
    String? directPeerId,
    bool showReadSection = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ReadReceiptDetailsSheet(
        messageId: messageId,
        localUserId: localUserId,
        deliveryStatusLabel: deliveryStatusLabel,
        groupId: groupId,
        messageAuthorId: messageAuthorId,
        groupMemberIds: groupMemberIds,
        directPeerId: directPeerId,
        showReadSection: showReadSection,
      ),
    );
  }

  Future<List<ReadReceiptMember>> _loadMembers() async {
    final receipts = await MessageReadReceiptsDb.getReceiptsForMessage(
      wireMessageId: messageId,
      groupId: groupId,
    );
    final readBy = <String, int>{
      for (final row in receipts)
        row['readerId'] as String: row['readAt'] as int,
    };

    if (groupId == null) {
      final peerId = directPeerId ??
          readBy.keys.firstWhere(
            (id) => id != localUserId,
            orElse: () => readBy.keys.isNotEmpty ? readBy.keys.first : '',
          );
      if (peerId.isEmpty) return [];
      final user = await DBHelper.getUserById(peerId);
      final name = user?['customName'] as String? ??
          user?['name'] as String? ??
          peerId;
      return [
        ReadReceiptMember(
          memberId: peerId,
          displayName: name,
          readAt: readBy[peerId],
          isPending: !readBy.containsKey(peerId),
        ),
      ];
    }

    final memberIds = groupMemberIds ??
        (await DBHelper.getGroupMembers(groupId!))
            .map((m) => m['memberId'] as String)
            .toList();

    final expected = memberIds
        .where((id) => id != messageAuthorId && id != localUserId)
        .toList();

    final members = <ReadReceiptMember>[];
    for (final id in expected) {
      final user = await DBHelper.getUserById(id);
      final name =
          user?['customName'] as String? ?? user?['name'] as String? ?? id;
      final readAt = readBy[id];
      members.add(
        ReadReceiptMember(
          memberId: id,
          displayName: name,
          readAt: readAt,
          isPending: readAt == null,
        ),
      );
    }

    members.sort((a, b) {
      if (a.readAt == null && b.readAt == null) return 0;
      if (a.readAt == null) return 1;
      if (b.readAt == null) return -1;
      return a.readAt!.compareTo(b.readAt!);
    });
    return members;
  }

  String _formatTime(int? millis) {
    if (millis == null) return 'Pending';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Message info',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.local_shipping_outlined, size: 20),
              title: const Text('Delivery'),
              trailing: Text(
                deliveryStatusLabel,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (showReadSection) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  'Read by',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
            if (showReadSection)
            FutureBuilder<List<ReadReceiptMember>>(
              future: _loadMembers(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final members = snapshot.data ?? [];
                if (members.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No read information available.'),
                  );
                }
                return Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: members.length,
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final member = members[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(member.displayName),
                        trailing: Text(
                          _formatTime(member.readAt),
                          style: TextStyle(
                            color: member.isPending
                                ? Theme.of(context).colorScheme.outline
                                : null,
                            fontSize: 13,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
