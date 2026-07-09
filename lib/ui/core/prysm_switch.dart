import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';

/// Material-free toggle switch.
class PrysmSwitch extends StatelessWidget {
  const PrysmSwitch({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final enabled = onChanged != null;
    final trackColor = value
        ? tokens.accent
        : tokens.outline.withValues(alpha: enabled ? 1 : 0.5);
    final thumbColor = tokens.onAccent;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => onChanged!(!value) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: value ? thumbColor : tokens.surfaceElevated,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class PrysmSwitchRow extends StatelessWidget {
  const PrysmSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PrysmTokens.spacing16,
        vertical: PrysmTokens.spacing12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: style.title),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: style.caption),
                ],
              ],
            ),
          ),
          PrysmSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
