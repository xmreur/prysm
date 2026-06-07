class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  bool get hasContent =>
      (title != null && title!.isNotEmpty) ||
      (description != null && description!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty);

  String get displayHost {
    final uri = Uri.tryParse(url);
    return uri?.host ?? url;
  }
}
