import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:prysm/models/link_preview.dart';
import 'package:prysm/services/link_unfurl_service.dart';
import 'package:prysm/services/settings_service.dart';

class LinkUnfurlPreview extends StatefulWidget {
  final String url;
  final Color textColor;
  final VoidCallback onOpen;

  const LinkUnfurlPreview({
    required this.url,
    required this.textColor,
    required this.onOpen,
    super.key,
  });

  @override
  State<LinkUnfurlPreview> createState() => _LinkUnfurlPreviewState();
}

class _LinkUnfurlPreviewState extends State<LinkUnfurlPreview> {
  LinkPreview? _preview;
  Uint8List? _imageBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (SettingsService().enableLinkUnfurling) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    final preview = await LinkUnfurlService.instance.fetch(widget.url);
    Uint8List? imageBytes;
    final imageUrl = preview?.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      imageBytes = await LinkUnfurlService.instance.fetchImage(imageUrl);
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _imageBytes = imageBytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!SettingsService().enableLinkUnfurling) {
      return const SizedBox.shrink();
    }
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SizedBox(
          height: 4,
          child: LinearProgressIndicator(
            color: widget.textColor.withValues(alpha: 0.5),
            backgroundColor: widget.textColor.withValues(alpha: 0.15),
          ),
        ),
      );
    }
    final preview = _preview;
    if (preview == null || !preview.hasContent) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: widget.textColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_imageBytes != null && _imageBytes!.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                  child: Image.memory(
                    _imageBytes!,
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.siteName != null && preview.siteName!.isNotEmpty)
                      Text(
                        preview.siteName!,
                        style: TextStyle(
                          fontSize: 11,
                          color: widget.textColor.withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (preview.title != null && preview.title!.isNotEmpty) ...[
                      if (preview.siteName != null) const SizedBox(height: 2),
                      Text(
                        preview.title!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: widget.textColor,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (preview.description != null &&
                        preview.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        preview.description!,
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.textColor.withValues(alpha: 0.85),
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
