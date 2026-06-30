import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prysm/crypto/wire.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/services/file_attachment_resolver.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/group_crypto.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/waveform_extractor.dart';

class VoicePlaybackInfo {
  final String localPath;
  final int durationMs;
  final List<double> peaks;

  const VoicePlaybackInfo({
    required this.localPath,
    required this.durationMs,
    required this.peaks,
  });
}

/// Loads and decrypts media rows for the in-chat gallery.
class ChatMediaService {
  final KeyManager keyManager;
  final String userId;
  final String? peerId;
  final String? groupId;
  final GroupService? groupService;
  final int? joinedAt;

  ChatMediaService.direct({
    required this.keyManager,
    required this.userId,
    required this.peerId,
  })  : groupId = null,
        groupService = null,
        joinedAt = null;

  ChatMediaService.group({
    required this.keyManager,
    required this.userId,
    required this.groupId,
    required this.groupService,
    this.joinedAt,
  })  : peerId = null;

  bool get isGroup => groupId != null;

  Future<List<ChatMediaItem>> loadPage(
    ChatMediaFilter filter, {
    int limit = 50,
    int? beforeTimestamp,
  }) async {
    final typeFilter = dbTypeForFilter(filter, isGroup: isGroup);
    final List<Map<String, dynamic>> rows;
    if (isGroup) {
      rows = await MessagesDb.getMediaMessagesForGroup(
        groupId!,
        typeFilter: typeFilter,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
        afterTimestamp: joinedAt,
      );
    } else {
      rows = await MessagesDb.getMediaMessagesForDirect(
        userId,
        peerId!,
        typeFilter: typeFilter,
        limit: limit,
        beforeTimestamp: beforeTimestamp,
      );
    }
    return rows
        .map((row) => ChatMediaItem.fromRow(row, isGroup: isGroup))
        .toList();
  }

  Future<Map<String, dynamic>> _rowForItem(ChatMediaItem item) async {
    final rows = await MessagesDb.getMessageById(
      item.id,
      groupId: groupId,
    );
    if (rows.isEmpty) {
      throw StateError('Message not found: ${item.id}');
    }
    return rows.first;
  }

  Future<Uint8List> decryptImageBytes(ChatMediaItem item) async {
    final row = await _rowForItem(item);
    final wire = row['message'] as String?;
    if (wire == null || wire.isEmpty) {
      throw StateError('Empty image payload: ${item.id}');
    }
    if (isGroup) {
      return _decryptGroupBytes(row);
    }
    return FileAttachmentResolver.decryptEncryptedSource(wire, keyManager);
  }

  Future<Uint8List> resolveFileBytes(ChatMediaItem item) async {
    final row = await _rowForItem(item);
    if (isGroup) {
      return _decryptGroupBytes(row);
    }
    final message = _fileMessageFromRow(row, item);
    return FileAttachmentResolver.resolve(message, keyManager: keyManager);
  }

  Future<VoicePlaybackInfo> resolveVoicePlayback(ChatMediaItem item) async {
    final row = await _rowForItem(item);
    final cacheDir = await getTemporaryDirectory();
    final cachePath =
        '${cacheDir.path}/${isGroup ? 'group' : 'direct'}_voice_${item.id}.wav';

    if (isGroup) {
      final bytes = await _decryptGroupBytes(row);
      await File(cachePath).writeAsBytes(bytes);
      final durationMs = WaveformExtractor.estimateDurationMs(bytes);
      final peaks = WaveformExtractor.extractPeaks(bytes);
      return VoicePlaybackInfo(
        localPath: cachePath,
        durationMs: durationMs,
        peaks: peaks,
      );
    }

    final fileName = row['fileName'] as String? ?? 'voice_message.wav';
    final message = FileMessage(
      id: item.id,
      authorId: row['senderId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(item.timestamp),
      name: fileName,
      size: item.fileSize ?? 0,
      source: row['message'] as String? ?? '',
    );

    if (message.source.startsWith('audio:')) {
      final parts = message.source.split(':');
      final durationMs = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
      final path = parts.length > 2 ? parts.sublist(2).join(':') : cachePath;
      return VoicePlaybackInfo(
        localPath: path,
        durationMs: durationMs,
        peaks: const [],
      );
    }

    final bytes = await FileAttachmentResolver.resolve(
      message,
      keyManager: keyManager,
    );
    await File(cachePath).writeAsBytes(bytes);
    final durationMs = WaveformExtractor.estimateDurationMs(bytes);
    final peaks = WaveformExtractor.extractPeaks(bytes);
    return VoicePlaybackInfo(
      localPath: cachePath,
      durationMs: durationMs,
      peaks: peaks,
    );
  }

  Future<Uint8List> Function() decryptCallbackForItem(ChatMediaItem item) {
    return () => decryptImageBytes(item);
  }

  Future<Uint8List?> Function(String encryptedSource)? voiceDecryptCallback() {
    if (isGroup) return null;
    return (encryptedSource) async {
      return CryptoWire.decryptFile(encryptedSource, keyManager.identity);
    };
  }

  FileMessage fileMessageForVoice(
    ChatMediaItem item,
    VoicePlaybackInfo playback,
  ) {
    return FileMessage(
      id: item.id,
      authorId: item.senderId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(item.timestamp),
      name: item.fileName ?? 'voice_message.wav',
      size: item.fileSize ?? 0,
      source: 'audio:${playback.durationMs}:${playback.localPath}',
      metadata: playback.peaks.isEmpty
          ? null
          : {'waveform': WaveformExtractor.encodePeaks(playback.peaks)},
    );
  }

  Future<Uint8List> _decryptGroupBytes(Map<String, dynamic> row) async {
    final groupKey =
        await groupService!.getDecryptedGroupKey(groupId!);
    if (groupKey == null) {
      throw StateError('No group key for $groupId');
    }
    return GroupCrypto.decryptGroupFile(
      groupKey,
      row['message'] as String,
    );
  }

  FileMessage _fileMessageFromRow(
    Map<String, dynamic> row,
    ChatMediaItem item,
  ) {
    final wire = row['message'] as String? ?? '';
    if (isGroup) {
      return FileMessage(
        id: item.id,
        authorId: item.senderId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(item.timestamp),
        name: item.fileName ?? 'file',
        size: item.fileSize ?? 0,
        source: base64Encode([]),
      );
    }
    return FileMessage(
      id: item.id,
      authorId: item.senderId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(item.timestamp),
      name: item.fileName ?? 'file',
      size: item.fileSize ?? 0,
      source: wire,
    );
  }

  String deferredImageSource(ChatMediaItem item) =>
      deferredImageSourceFor(item.id);
}
