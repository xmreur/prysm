import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:prysm/screens/widgets/link_unfurl_preview.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/util/url_detector.dart';

class LinkedMessageText extends StatelessWidget {
  final String text;
  final Color textColor;
  final double fontSize;
  final Future<void> Function(String url) onOpenUrl;
  final String? highlightQuery;

  const LinkedMessageText({
    required this.text,
    required this.textColor,
    required this.fontSize,
    required this.onOpenUrl,
    this.highlightQuery,
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
    final query = highlightQuery?.trim().toLowerCase();
    final matches = UrlDetector.urlRegex.allMatches(text).toList();
    final spans = <InlineSpan>[];
    var lastEnd = 0;

    void appendHighlightedSegment(int start, int end) {
      if (end <= start) return;
      spans.addAll(_highlightSpans(text.substring(start, end), query: query));
    }

    for (final match in matches) {
      if (match.start > lastEnd) {
        appendHighlightedSegment(lastEnd, match.start);
      }
      final url = match.group(0)!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => onOpenUrl(url),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: url));
            showPrysmToast(context, 'Link copied');
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

    appendHighlightedSegment(lastEnd, text.length);

    return RichText(text: TextSpan(children: spans));
  }

  /// Builds spans for [segment], highlighting query token matches when a
  /// non-empty query is active. [query] is pre-lowercased by the caller.
  List<TextSpan> _highlightSpans(String segment, {String? query}) {
    final highlight = query != null && query.length >= 2;
    if (!highlight) {
      return [
        TextSpan(
          text: segment,
          style: TextStyle(color: textColor, fontSize: fontSize),
        ),
      ];
    }

    final lower = segment.toLowerCase();
    final tokens =
        query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final spans = <TextSpan>[];
    var cursor = 0;

    while (cursor < segment.length) {
      var nextMatch = -1;
      var matchLen = 0;
      for (final token in tokens) {
        final idx = lower.indexOf(token, cursor);
        if (idx >= 0 && (nextMatch < 0 || idx < nextMatch)) {
          nextMatch = idx;
          matchLen = token.length;
        }
      }
      if (nextMatch < 0) {
        spans.add(TextSpan(
          text: segment.substring(cursor),
          style: TextStyle(color: textColor, fontSize: fontSize),
        ));
        break;
      }
      if (nextMatch > cursor) {
        spans.add(TextSpan(
          text: segment.substring(cursor, nextMatch),
          style: TextStyle(color: textColor, fontSize: fontSize),
        ));
      }
      spans.add(TextSpan(
        text: segment.substring(nextMatch, nextMatch + matchLen),
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          backgroundColor: textColor.withValues(alpha: 0.25),
        ),
      ));
      cursor = nextMatch + matchLen;
    }

    return spans;
  }
}
