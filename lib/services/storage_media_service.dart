import 'dart:typed_data';

import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/storage_media_item.dart';
import 'package:prysm/services/chat_media_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_content_wiper.dart';

/// Loads and manages media across every conversation for the storage browser.
class StorageMediaService {
  final KeyManager keyManager;
  final String userId;
  final GroupService groupService;
  final Map<String, String> contactNames;
  final Map<String, String> groupNames;

  StorageMediaService({
    required this.keyManager,
    required this.userId,
    required this.groupService,
    required this.contactNames,
    required this.groupNames,
  });

  Future<List<StorageMediaItem>> loadPage(
    ChatMediaFilter filter, {
    int limit = 50,
    int? beforeTimestamp,
  }) async {
    final rows = await MessagesDb.getAllMediaMessages(
      types: globalTypesForFilter(filter),
      limit: limit,
      beforeTimestamp: beforeTimestamp,
    );
    return rows
        .map(
          (row) => StorageMediaItem.fromRow(
            row,
            userId: userId,
            contactNames: contactNames,
            groupNames: groupNames,
          ),
        )
        .toList();
  }

  Future<int> countMedia(ChatMediaFilter filter) {
    return MessagesDb.countAllMediaMessages(
      types: globalTypesForFilter(filter),
    );
  }

  ChatMediaService _scopedService(StorageMediaItem item) {
    if (item.isGroup) {
      return ChatMediaService.group(
        keyManager: keyManager,
        userId: userId,
        groupId: item.groupId!,
        groupService: groupService,
      );
    }
    return ChatMediaService.direct(
      keyManager: keyManager,
      userId: userId,
      peerId: item.peerId!,
    );
  }

  Future<Uint8List> decryptImageBytes(StorageMediaItem item) {
    return _scopedService(item).decryptImageBytes(item.toChatMediaItem());
  }

  Future<Uint8List> resolveFileBytes(StorageMediaItem item) {
    return _scopedService(item).resolveFileBytes(item.toChatMediaItem());
  }

  Future<VoicePlaybackInfo> resolveVoicePlayback(StorageMediaItem item) {
    return _scopedService(item)
        .resolveVoicePlayback(item.toChatMediaItem());
  }

  Future<Uint8List> Function() decryptCallbackForItem(StorageMediaItem item) {
    return _scopedService(item)
        .decryptCallbackForItem(item.toChatMediaItem());
  }

  Future<Uint8List?> Function(String encryptedSource)? voiceDecryptCallback(
    StorageMediaItem item,
  ) {
    return _scopedService(item).voiceDecryptCallback();
  }

  FileMessage fileMessageForVoice(
    StorageMediaItem item,
    VoicePlaybackInfo playback,
  ) {
    return _scopedService(item)
        .fileMessageForVoice(item.toChatMediaItem(), playback);
  }

  Future<void> deleteLocally(StorageMediaItem item) async {
    await MessageContentWiper.wipeLocalArtifacts(
      wireId: item.id,
      groupId: item.groupId,
    );
    await MessagesDb.hardDeleteMessage(item.id, groupId: item.groupId);
  }
}
