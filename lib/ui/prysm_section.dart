import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';

class PrysmSectionHeader extends StatelessWidget {
  const PrysmSectionHeader({
    required this.title,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PrysmTokens.spacing16,
        PrysmTokens.spacing20,
        PrysmTokens.spacing16,
        PrysmTokens.spacing8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: style.captionStyle.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: tokens.textMuted,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class PrysmSection extends StatelessWidget {
  const PrysmSection({
    required this.children,
    this.header,
    super.key,
  });

  final String? header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) PrysmSectionHeader(title: header!),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: PrysmTokens.spacing16),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: _withDividers(children, tokens.divider),
          ),
        ),
      ],
    );
  }

  List<Widget> _withDividers(List<Widget> items, Color divider) {
    if (items.isEmpty) return items;
    final result = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      result.add(items[i]);
      if (i < items.length - 1) {
        result.add(Container(height: 1, margin: const EdgeInsets.only(left: 56), color: divider));
      }
    }
    return result;
  }
}
