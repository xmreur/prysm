const String kImageSourceScheme = 'prysm-image://';

bool isDeferredImageSource(String source) =>
    source.startsWith(kImageSourceScheme);

String deferredImageSourceFor(String messageId) =>
    '$kImageSourceScheme$messageId';

String? messageIdFromDeferredImageSource(String source) {
  if (!isDeferredImageSource(source)) return null;
  final id = source.substring(kImageSourceScheme.length);
  return id.isEmpty ? null : id;
}
