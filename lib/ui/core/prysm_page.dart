import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';

/// Screen chrome without Scaffold/AppBar.
class PrysmPage extends StatelessWidget {
  const PrysmPage({
    required this.body,
    this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.backgroundColor,
    super.key,
  });

  final Widget body;
  final String? title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final hasHeader =
        title != null || leading != null || actions.isNotEmpty;

    return ColoredBox(
      color: backgroundColor ?? tokens.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasHeader)
              ColoredBox(
                color: tokens.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 56,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PrysmTokens.spacing8,
                        ),
                        child: Row(
                          children: [
                            ?leading,
                            if (title != null)
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title!, style: style.titleStyle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    if (subtitle != null)
                                      Text(subtitle!,
                                          style: style.captionStyle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              )
                            else
                              const Spacer(),
                            ...actions,
                          ],
                        ),
                      ),
                    ),
                    Container(height: 1, color: tokens.divider),
                  ],
                ),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
