enum SharedContentKind { text, file }

/// Payload received from the OS share sheet (one item; multi-share uses the first).
class SharedContent {
  const SharedContent({
    required this.kind,
    this.text,
    this.filePath,
    this.mimeType,
    this.fileName,
  });

  final SharedContentKind kind;
  final String? text;
  final String? filePath;
  final String? mimeType;
  final String? fileName;

  bool get isText => kind == SharedContentKind.text;

  bool get isFile => kind == SharedContentKind.file;
}
