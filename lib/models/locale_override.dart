/// User-selected language override stored in [Settings].
enum LocaleOverride {
  system,
  en,
  it;

  static const String systemKey = 'system';

  String get storageKey => switch (this) {
        LocaleOverride.system => systemKey,
        LocaleOverride.en => 'en',
        LocaleOverride.it => 'it',
      };

  static LocaleOverride fromJson(String? value) {
    return LocaleOverride.values.firstWhere(
      (o) => o.storageKey == value,
      orElse: () => LocaleOverride.system,
    );
  }
}
