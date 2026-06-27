enum ReplyPreviewKind {
  text,
  image,
  file,
  voice,
  deleted,
  unavailable,
}

class ReplyPreviewData {
  final String messageId;
  final String? authorId;
  final String label;
  final ReplyPreviewKind kind;

  const ReplyPreviewData({
    required this.messageId,
    required this.authorId,
    required this.label,
    required this.kind,
  });

  static const unavailable = ReplyPreviewData(
    messageId: '',
    authorId: null,
    label: 'Original message unavailable',
    kind: ReplyPreviewKind.unavailable,
  );
}
