import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Downloads and verifies the on-device English STT model (Whisper tiny.en).
class SttModelManager {
  SttModelManager._();
  static final SttModelManager instance = SttModelManager._();

  static const supportedLanguageLabel = 'English';

  static const modelFolderName = 'sherpa-onnx-whisper-tiny.en';
  static const encoderFile = 'tiny.en-encoder.int8.onnx';
  static const decoderFile = 'tiny.en-decoder.int8.onnx';
  static const tokensFile = 'tiny.en-tokens.txt';

  static const _downloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2';

  Future<String>? _downloadFuture;

  Future<String> modelsRootDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    return p.join(docDir.path, 'prysm', 'stt_models');
  }

  Future<String> modelDir() async {
    return p.join(await modelsRootDir(), modelFolderName);
  }

  Future<bool> isModelInstalled() async {
    final dir = Directory(await modelDir());
    if (!await dir.exists()) return false;
    for (final name in [encoderFile, decoderFile, tokensFile]) {
      if (!await File(p.join(dir.path, name)).exists()) {
        return false;
      }
    }
    return true;
  }

  /// Returns the model directory path, downloading and extracting if needed.
  Future<String> ensureModelReady({
    void Function(double progress)? onProgress,
  }) async {
    if (await isModelInstalled()) {
      onProgress?.call(1.0);
      return modelDir();
    }

    _downloadFuture ??= _downloadAndExtract(onProgress: onProgress);
    try {
      return await _downloadFuture!;
    } finally {
      _downloadFuture = null;
    }
  }

  Future<String> _downloadAndExtract({
    void Function(double progress)? onProgress,
  }) async {
    final root = await modelsRootDir();
    await Directory(root).create(recursive: true);

    final archivePath = p.join(root, '$modelFolderName.tar.bz2');
    final archiveFile = File(archivePath);

    onProgress?.call(0.0);
    final response = await http.Client().send(http.Request('GET', Uri.parse(_downloadUrl)));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('STT model download failed (${response.statusCode})');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = archiveFile.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 0.9));
        }
      }
    } finally {
      await sink.close();
    }

    onProgress?.call(0.92);
    await _extractArchive(archiveFile, root);
    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }

    if (!await isModelInstalled()) {
      throw StateError('STT model extraction failed');
    }

    onProgress?.call(1.0);
    return modelDir();
  }

  Future<void> _extractArchive(File archiveFile, String destRoot) async {
    final bytes = await archiveFile.readAsBytes();
    final decompressed = BZip2Decoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(decompressed);

    for (final file in archive) {
      if (file.isFile) {
        final outPath = p.join(destRoot, file.name);
        await Directory(p.dirname(outPath)).create(recursive: true);
        await File(outPath).writeAsBytes(file.content as List<int>);
      }
    }
  }
}
