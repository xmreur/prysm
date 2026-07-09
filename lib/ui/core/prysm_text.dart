import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

class PrysmText extends StatelessWidget {
  const PrysmText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final resolved = style ?? context.prysmStyle.bodyStyle;
    return Text(
      data,
      style: resolved,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
