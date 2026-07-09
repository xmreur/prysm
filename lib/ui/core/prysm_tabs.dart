import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

class PrysmTabController extends ChangeNotifier {
  PrysmTabController({required this.length, int initialIndex = 0})
      : assert(length > 0),
        _index = initialIndex.clamp(0, length - 1);

  final int length;
  int _index;

  int get index => _index;

  set index(int value) {
    final next = value.clamp(0, length - 1);
    if (next == _index) return;
    _index = next;
    notifyListeners();
  }


}

class PrysmTabBar extends StatelessWidget {
  const PrysmTabBar({
    required this.controller,
    required this.tabs,
    super.key,
  });

  final PrysmTabController controller;
  final List<String> tabs;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SizedBox(
          height: 44,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: PrysmPressable(
                    onTap: () => controller.index = i,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: controller.index == i
                                ? tokens.accent
                                : tokens.divider,
                            width: controller.index == i ? 2 : 1,
                          ),
                        ),
                      ),
                      child: Text(
                        tabs[i],
                        style: style.bodyStyle.copyWith(
                          color: controller.index == i
                              ? tokens.accent
                              : tokens.textSecondary,
                          fontWeight: controller.index == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class PrysmTabBarView extends StatelessWidget {
  const PrysmTabBarView({
    required this.controller,
    required this.children,
    super.key,
  });

  final PrysmTabController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return IndexedStack(
          index: controller.index,
          children: children,
        );
      },
    );
  }
}

class PrysmFab extends StatelessWidget {
  const PrysmFab({
    required this.icon,
    required this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final bg = backgroundColor ?? tokens.accent;
    final fg = foregroundColor ?? tokens.onAccent;
    return PrysmPressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(28),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: onPressed == null
              ? Color.lerp(bg, tokens.background, 0.4)
              : bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: bg.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: fg, size: 24),
      ),
    );
  }
}
