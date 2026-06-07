enum PanicAction {
  decoy,
  wipe;

  String get label => switch (this) {
        PanicAction.decoy => 'Decoy profile',
        PanicAction.wipe => 'Wipe local keys',
      };

  String get description => switch (this) {
        PanicAction.decoy =>
          'Show an empty app while your real data stays encrypted on disk',
        PanicAction.wipe =>
          'Destroy keys and local databases, then show an empty app',
      };

  static PanicAction fromJson(String? value) {
    return PanicAction.values.firstWhere(
      (a) => a.name == value,
      orElse: () => PanicAction.decoy,
    );
  }
}
