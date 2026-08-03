import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/services/pending_share_store.dart';
import 'package:prysm/util/logging.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

typedef ShareDecoyModeCheck = bool Function();

/// Listens for inbound OS share intents on Android.
class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  StreamSubscription<List<SharedMediaFile>>? _mediaSub;
  bool _initialized = false;

  ShareDecoyModeCheck? isDecoyMode;
  void Function()? onPendingShare;

  Future<void> init() async {
    if (_initialized) return;
    if (!Platform.isAndroid) return;

    _initialized = true;

    _mediaSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleMedia,
      onError: (Object error, StackTrace stack) {
        Logging.error('Share media stream error: $error\n$stack', 'ShareIntent');
      },
    );

    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      _handleMedia(initial);
    } catch (error, stack) {
      Logging.error('Share initial media error: $error\n$stack', 'ShareIntent');
    }
  }

  Future<void> dispose() async {
    await _mediaSub?.cancel();
    _mediaSub = null;
    _initialized = false;
  }

  void _handleMedia(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    if (isDecoyMode?.call() == true) {
      unawaited(ReceiveSharingIntent.instance.reset());
      return;
    }

    // Multi-item shares: only the first item is forwarded.
    final content = _mapFirst(files.first);
    if (content == null) {
      unawaited(ReceiveSharingIntent.instance.reset());
      return;
    }

    PendingShareStore.instance.set(content);
    unawaited(ReceiveSharingIntent.instance.reset());
    onPendingShare?.call();
  }

  static SharedContent? mapMediaFile(SharedMediaFile file) => _mapFirst(file);

  static SharedContent? _mapFirst(SharedMediaFile file) {
    switch (file.type) {
      case SharedMediaType.text:
      case SharedMediaType.url:
        final text = file.path.trim();
        if (text.isEmpty) return null;
        return SharedContent(kind: SharedContentKind.text, text: text);
      case SharedMediaType.image:
      case SharedMediaType.video:
      case SharedMediaType.file:
        final path = file.path.trim();
        if (path.isEmpty) return null;
        final fileName = p.basename(Uri.parse(path).path);
        return SharedContent(
          kind: SharedContentKind.file,
          filePath: path,
          mimeType: file.mimeType,
          fileName: fileName.isEmpty ? 'shared_file' : fileName,
        );
    }
  }
}
