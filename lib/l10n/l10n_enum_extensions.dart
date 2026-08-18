import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/models/appearance_settings.dart';
import 'package:prysm/models/chat_media_item.dart';
import 'package:prysm/models/disappearing_timer.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/models/panic_action.dart';

extension GroupInviteModeL10n on GroupInviteMode {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        GroupInviteMode.holdAsRequest => l10n.groupInviteHoldTitle,
        GroupInviteMode.contactsOnly => l10n.groupInviteContactsOnlyTitle,
      };

  String localizedDescription(AppLocalizations l10n) => switch (this) {
        GroupInviteMode.holdAsRequest => l10n.groupInviteHoldDescription,
        GroupInviteMode.contactsOnly => l10n.groupInviteContactsOnlyDescription,
      };
}

extension PanicActionL10n on PanicAction {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        PanicAction.decoy => l10n.panicDecoyTitle,
        PanicAction.wipe => l10n.panicWipeTitle,
      };

  String localizedDescription(AppLocalizations l10n) => switch (this) {
        PanicAction.decoy => l10n.panicDecoyDescription,
        PanicAction.wipe => l10n.panicWipeDescription,
      };
}

extension PrysmFontFamilyL10n on PrysmFontFamily {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        PrysmFontFamily.system => l10n.fontSystem,
        PrysmFontFamily.inter => l10n.fontInter,
        PrysmFontFamily.ibmPlexSans => l10n.fontIbmPlexSans,
        PrysmFontFamily.jetBrainsMono => l10n.fontJetBrainsMono,
      };
}

extension DisappearingTimerPresetL10n on DisappearingTimerPreset {
  String localizedLabel(AppLocalizations l10n) {
    return switch (seconds) {
      0 => l10n.disappearingOff,
      30 => l10n.disappearing30s,
      300 => l10n.disappearing5m,
      3600 => l10n.disappearing1h,
      28800 => l10n.disappearing8h,
      86400 => l10n.disappearing1d,
      604800 => l10n.disappearing1w,
      2419200 => l10n.disappearing4w,
      _ => label,
    };
  }
}

String disappearingTimerLabelForSeconds(AppLocalizations l10n, int? seconds) {
  if (seconds == null || seconds <= 0) return l10n.disappearingOff;
  for (final preset in DisappearingTimerPresets.all) {
    if (preset.seconds == seconds) {
      return preset.localizedLabel(l10n);
    }
  }
  if (seconds < 60) return l10n.disappearingDurationSeconds(seconds);
  if (seconds < 3600) return l10n.disappearingDurationMinutes(seconds ~/ 60);
  if (seconds < 86400) return l10n.disappearingDurationHours(seconds ~/ 3600);
  if (seconds < 604800) return l10n.disappearingDurationDays(seconds ~/ 86400);
  return l10n.disappearingDurationWeeks(seconds ~/ 604800);
}

extension ChatMediaFilterL10n on ChatMediaFilter {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        ChatMediaFilter.all => l10n.chatMediaFilterAll,
        ChatMediaFilter.photos => l10n.chatMediaFilterPhotos,
        ChatMediaFilter.files => l10n.chatMediaFilterFiles,
        ChatMediaFilter.voice => l10n.chatMediaFilterVoice,
      };
}
