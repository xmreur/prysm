import 'package:flutter/widgets.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/core/prysm_slider.dart';
import 'package:prysm/ui/core/prysm_chip.dart';

/// Appearance customization controls with live bubble preview.
class AppearanceSettingsSection extends StatefulWidget {
  const AppearanceSettingsSection({
    required this.onChanged,
    super.key,
  });

  final VoidCallback onChanged;

  @override
  State<AppearanceSettingsSection> createState() =>
      _AppearanceSettingsSectionState();
}

class _AppearanceSettingsSectionState extends State<AppearanceSettingsSection> {
  final _settings = SettingsService();
  late AppearanceSettings _appearance;

  @override
  void initState() {
    super.initState();
    _appearance = _settings.appearance;
  }

  Future<void> _save(AppearanceSettings next) async {
    setState(() => _appearance = next.clamped());
    await _settings.setAppearance(_appearance);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _previewBubble(style),
        const SizedBox(height: 16),
        _fontPicker(),
        _slider(
          label: 'Text size',
          value: _appearance.textScale,
          min: AppearanceSettings.textScaleMin,
          max: AppearanceSettings.textScaleMax,
          divisions: 8,
          display: '${(_appearance.textScale * 100).round()}%',
          onChanged: (v) => _save(_appearance.copyWith(textScale: v)),
        ),
        _slider(
          label: 'Message bubble rounding',
          value: _appearance.messageBubbleRadius,
          min: AppearanceSettings.bubbleRadiusMin,
          max: AppearanceSettings.bubbleRadiusMax,
          divisions: 16,
          display: _appearance.messageBubbleRadius.round().toString(),
          onChanged: (v) =>
              _save(_appearance.copyWith(messageBubbleRadius: v)),
        ),
        PrysmSwitchRow(
          title: 'Message shadows',
          value: _appearance.messageShadows,
          onChanged: (v) => _save(_appearance.copyWith(messageShadows: v)),
        ),
        if (_appearance.messageShadows)
          _slider(
            label: 'Shadow strength',
            value: _appearance.messageShadowStrength,
            min: AppearanceSettings.shadowStrengthMin,
            max: AppearanceSettings.shadowStrengthMax,
            divisions: 6,
            display: _appearance.messageShadowStrength.toStringAsFixed(2),
            onChanged: (v) =>
                _save(_appearance.copyWith(messageShadowStrength: v)),
          ),
        _slider(
          label: 'Composer rounding',
          value: _appearance.composerRadius,
          min: AppearanceSettings.composerRadiusMin,
          max: AppearanceSettings.composerRadiusMax,
          divisions: 16,
          display: _appearance.composerRadius.round().toString(),
          onChanged: (v) => _save(_appearance.copyWith(composerRadius: v)),
        ),
      ],
    );
  }

  Widget _previewBubble(PrysmResolvedStyle style) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PrysmTokens.spacing16),
      child: Row(
        children: [
          Expanded(
            child: PrysmBubbleRenderer(
              isSentByMe: false,
              child: Text('Received preview', style: style.bodyStyle),
            ),
          ),
          const SizedBox(width: PrysmTokens.spacing12),
          Expanded(
            child: PrysmBubbleRenderer(
              isSentByMe: true,
              child: Text(
                'Sent preview',
                style: style.bodyStyle.copyWith(
                  color: style.tokens.onAccent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fontPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PrysmTokens.spacing16,
        vertical: PrysmTokens.spacing8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Font', style: context.prysmStyle.title),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: PrysmFontFamily.values.map((font) {
              final selected = _appearance.fontFamily == font;
              return PrysmChip(
                label: font.label,
                selected: selected,
                onSelected: (_) => _save(_appearance.copyWith(fontFamily: font)),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PrysmTokens.spacing16,
        vertical: PrysmTokens.spacing8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: context.prysmStyle.body)),
              Text(display, style: context.prysmStyle.caption),
            ],
          ),
          PrysmSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
