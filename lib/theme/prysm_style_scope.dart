import 'package:flutter/widgets.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';

class PrysmStyleScope extends InheritedWidget {
  const PrysmStyleScope({
    required this.style,
    required super.child,
    super.key,
  });

  final PrysmResolvedStyle style;

  static PrysmResolvedStyle of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PrysmStyleScope>();
    assert(scope != null, 'PrysmStyleScope not found');
    return scope!.style;
  }

  static PrysmResolvedStyle? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PrysmStyleScope>()
        ?.style;
  }

  @override
  bool updateShouldNotify(PrysmStyleScope oldWidget) =>
      oldWidget.style.appearance != style.appearance ||
      oldWidget.style.palette.index != style.palette.index;
}

extension PrysmStyleContext on BuildContext {
  PrysmResolvedStyle get prysmStyle => PrysmStyleScope.of(this);
}

/// Builds [PrysmStyleScope] from palette index + appearance prefs.
class PrysmStyleProvider extends StatefulWidget {
  const PrysmStyleProvider({
    required this.themePalette,
    required this.appearance,
    required this.child,
    super.key,
  });

  final int themePalette;
  final AppearanceSettings appearance;
  final Widget child;

  @override
  State<PrysmStyleProvider> createState() => _PrysmStyleProviderState();
}

class _PrysmStyleProviderState extends State<PrysmStyleProvider> {
  final _settings = SettingsService();

  @override
  void initState() {
    super.initState();
    _settings.styleRevision.addListener(_onStyleRevision);
  }

  @override
  void dispose() {
    _settings.styleRevision.removeListener(_onStyleRevision);
    super.dispose();
  }

  void _onStyleRevision() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final style = PrysmStyleResolver.resolve(
      themePalette: _settings.themeMode,
      appearance: _settings.appearance,
    );
    return PrysmStyleScope(style: style, child: widget.child);
  }
}
