import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prysm/screens/widgets/link_unfurl_preview.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/url_detector.dart';

class LinkedMessageText extends StatelessWidget {
  final String text;
  final Color textColor;
  final double fontSize;
  final Future<void> Function(String url) onOpenUrl;

  const LinkedMessageText({
    required this.text,
    required this.textColor,
    required this.fontSize,
    required this.onOpenUrl,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final firstUrl = UrlDetector.firstUrl(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildLinkedText(context),
        if (firstUrl != null && SettingsService().enableLinkUnfurling)
          LinkUnfurlPreview(
            url: firstUrl,
            textColor: textColor,
            onOpen: () => onOpenUrl(firstUrl),
          ),
      ],
    );
  }

  Widget _buildLinkedText(BuildContext context) {
    final matches = UrlDetector.urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: textColor, fontSize: fontSize));
    }

    final spans = <InlineSpan>[];
    var lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: textColor, fontSize: fontSize),
        ));
      }
      final url = match.group(0)!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => onOpenUrl(url),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Link copied'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          child: Text(
            url,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              decoration: TextDecoration.underline,
              decorationColor: textColor.withAlpha(180),
            ),
          ),
        ),
      ));
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: textColor, fontSize: fontSize),
      ));
    }

    return RichText(text: TextSpan(children: spans));
  }
}
