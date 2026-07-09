import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

class PrysmCheckboxRow extends StatelessWidget {
  const PrysmCheckboxRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.secondary,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return PrysmPressable(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PrysmTokens.spacing16,
          vertical: PrysmTokens.spacing12,
        ),
        child: Row(
          children: [
            _CheckboxBox(value: value, tokens: tokens),
            const SizedBox(width: PrysmTokens.spacing12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: style.titleStyle),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: style.captionStyle),
                  ],
                ],
              ),
            ),
            ?secondary,
          ],
        ),
      ),
    );
  }
}

class _CheckboxBox extends StatelessWidget {
  const _CheckboxBox({required this.value, required this.tokens});

  final bool value;
  final dynamic tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: value ? tokens.accent : tokens.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: value ? tokens.accent : tokens.outline),
      ),
      alignment: Alignment.center,
      child: value
          ? Icon(PrysmIcons.check, size: 14, color: tokens.onAccent)
          : null,
    );
  }
}
