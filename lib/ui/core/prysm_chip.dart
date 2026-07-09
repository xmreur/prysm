import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

class PrysmChip extends StatelessWidget {
  const PrysmChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final bg = selected
        ? Color.lerp(tokens.accent, tokens.background, 0.15)!
        : tokens.surfaceElevated;
    final fg = selected ? tokens.onAccent : tokens.textPrimary;

    return PrysmPressable(
      onTap: () => onSelected(!selected),
      borderRadius: BorderRadius.circular(PrysmTokens.radiusChip),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(PrysmTokens.radiusChip),
          border: Border.all(
            color: selected ? tokens.accent : tokens.outline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: style.captionStyle.copyWith(
              color: fg,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
