/// User-customizable appearance preferences (persisted in [Settings]).
class AppearanceSettings {
  const AppearanceSettings({
    this.fontFamily = PrysmFontFamily.system,
    this.textScale = 1.0,
    this.messageBubbleRadius = 14.0,
    this.messageShadows = false,
    this.messageShadowStrength = 0.15,
    this.composerRadius = 20.0,
  });

  final PrysmFontFamily fontFamily;
  final double textScale;
  final double messageBubbleRadius;
  final bool messageShadows;
  final double messageShadowStrength;
  final double composerRadius;

  static const textScaleMin = 0.85;
  static const textScaleMax = 1.25;
  static const bubbleRadiusMin = 4.0;
  static const bubbleRadiusMax = 20.0;
  static const composerRadiusMin = 12.0;
  static const composerRadiusMax = 28.0;
  static const shadowStrengthMin = 0.05;
  static const shadowStrengthMax = 0.35;

  String get fontFamilyKey => fontFamily.key;

  factory AppearanceSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AppearanceSettings();
    return AppearanceSettings(
      fontFamily: PrysmFontFamily.fromKey(json['fontFamily'] as String?),
      textScale: (json['textScale'] as num?)?.toDouble() ?? 1.0,
      messageBubbleRadius:
          (json['messageBubbleRadius'] as num?)?.toDouble() ?? 14.0,
      messageShadows: json['messageShadows'] as bool? ?? false,
      messageShadowStrength:
          (json['messageShadowStrength'] as num?)?.toDouble() ?? 0.15,
      composerRadius: (json['composerRadius'] as num?)?.toDouble() ?? 20.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'fontFamily': fontFamily.key,
        'textScale': textScale,
        'messageBubbleRadius': messageBubbleRadius,
        'messageShadows': messageShadows,
        'messageShadowStrength': messageShadowStrength,
        'composerRadius': composerRadius,
      };

  AppearanceSettings copyWith({
    PrysmFontFamily? fontFamily,
    double? textScale,
    double? messageBubbleRadius,
    bool? messageShadows,
    double? messageShadowStrength,
    double? composerRadius,
  }) {
    return AppearanceSettings(
      fontFamily: fontFamily ?? this.fontFamily,
      textScale: textScale ?? this.textScale,
      messageBubbleRadius: messageBubbleRadius ?? this.messageBubbleRadius,
      messageShadows: messageShadows ?? this.messageShadows,
      messageShadowStrength:
          messageShadowStrength ?? this.messageShadowStrength,
      composerRadius: composerRadius ?? this.composerRadius,
    );
  }

  AppearanceSettings clamped() {
    return copyWith(
      textScale: textScale.clamp(textScaleMin, textScaleMax),
      messageBubbleRadius:
          messageBubbleRadius.clamp(bubbleRadiusMin, bubbleRadiusMax),
      messageShadowStrength: messageShadowStrength.clamp(
        shadowStrengthMin,
        shadowStrengthMax,
      ),
      composerRadius:
          composerRadius.clamp(composerRadiusMin, composerRadiusMax),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppearanceSettings &&
        other.fontFamily == fontFamily &&
        other.textScale == textScale &&
        other.messageBubbleRadius == messageBubbleRadius &&
        other.messageShadows == messageShadows &&
        other.messageShadowStrength == messageShadowStrength &&
        other.composerRadius == composerRadius;
  }

  @override
  int get hashCode => Object.hash(
        fontFamily,
        textScale,
        messageBubbleRadius,
        messageShadows,
        messageShadowStrength,
        composerRadius,
      );
}

enum PrysmFontFamily {
  system('system', null, 'System'),
  inter('Inter', 'Inter', 'Inter'),
  ibmPlexSans('IBMPlexSans', 'IBMPlexSans', 'IBM Plex Sans'),
  jetBrainsMono('JetBrainsMono', 'JetBrainsMono', 'JetBrains Mono');

  const PrysmFontFamily(this.key, this.family, this.label);

  final String key;
  final String? family;
  final String label;

  static PrysmFontFamily fromKey(String? key) {
    return PrysmFontFamily.values.firstWhere(
      (f) => f.key == key,
      orElse: () => PrysmFontFamily.system,
    );
  }
}
