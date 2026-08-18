// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get aNewVersionIsAvailable => 'A new version is available.';

  @override
  String get aPanicPinIsASecondPasscodeEntering =>
      'A panic PIN is a second passcode. Entering it at unlock ';

  @override
  String get about => 'About';

  @override
  String aboutApp(String appName) {
    return 'About $appName';
  }

  @override
  String get aboutThisApp => 'About This App';

  @override
  String get accept => 'Accept';

  @override
  String get acceptCall => 'Accept call';

  @override
  String get activeCallsChannel => 'Active Calls';

  @override
  String get activeCallsChannelDescription => 'Ongoing voice calls';

  @override
  String get add => 'Add';

  @override
  String get addContact => 'Add contact';

  @override
  String get addContactAndJoin => 'Add contact and join';

  @override
  String get addContactOfflineHint =>
      'Connect to Tor to add contacts. You can skip this step and add friends later from the main app.';

  @override
  String get addContactOnlineHint =>
      'Ask a friend for their Prysm ID (a Base58 code or QR). They must be online on Tor for the first connection.';

  @override
  String get addContactsBeforeCreatingAGroup =>
      'Add contacts before creating a group';

  @override
  String get addMember => 'Add member';

  @override
  String get addYourFirstContact => 'Add your first contact';

  @override
  String addedMemberWillReceiveInviteWhenOnline(String name) {
    return 'Added $name. They will receive an invite when online.';
  }

  @override
  String get admin => 'Admin';

  @override
  String get advancedPrivacy => 'Advanced Privacy';

  @override
  String get after5FailedUnlockAttemptsLock2Hours =>
      'After 5 failed unlock attempts, Prysm locks for 2 hours';

  @override
  String get alignTheQrCodeInsideTheFrameTo =>
      'Align the QR code inside the frame to scan.';

  @override
  String get anInviteFromSomeoneWhoIsNotIn =>
      'An invite from someone who is not in your contacts is kept as a ';

  @override
  String get appTitle => 'Prysm';

  @override
  String get appearance => 'Appearance';

  @override
  String get archiveChat => 'Archive chat';

  @override
  String get archived => 'Archived';

  @override
  String get areYouSureYouWantToDeleteAll =>
      'Are you sure you want to delete all messages in this chat? This cannot be undone.';

  @override
  String get areYouSureYouWantToDeleteThis =>
      'Are you sure you want to delete this contact? This cannot be undone.';

  @override
  String get askYourContactToShowThisCodeOr =>
      'Ask your contact to show this code, or scan theirs to verify.';

  @override
  String get audioNotReady => 'Audio not ready';

  @override
  String get autoRestarts => 'Auto-restarts: ';

  @override
  String get autoRestartsLabel => 'Auto-restarts:';

  @override
  String get back => 'Back';

  @override
  String get backToChats => 'Back to chats';

  @override
  String get backUpYourAccount => 'Back up your account';

  @override
  String get backupCreateAnytimeInSettings =>
      'You can create more backups anytime in Settings → Data';

  @override
  String get backupCreated => 'Backup created';

  @override
  String get backupEncryptedFileBullet =>
      'Backups are password-encrypted files (.prysmbackup)';

  @override
  String backupFailedE(String e) {
    return 'Backup failed: $e';
  }

  @override
  String get backupOnboardingBody =>
      'A backup saves your chats, contacts, and encrypted keys. Without one, losing this device or forgetting your unlock code means losing everything.';

  @override
  String get backupPassword => 'Backup Password';

  @override
  String get backupRestoredPleaseRestartTheApp =>
      'Backup restored! Please restart the app.';

  @override
  String backupSavedTo(String path) {
    return 'Backup saved to $path';
  }

  @override
  String get backupStoreOutsideDevice =>
      'Store the file somewhere safe outside this device';

  @override
  String batterySaverAutoEnabledBatteryAt(int level) {
    return 'Auto-enabled — battery at $level%';
  }

  @override
  String get batterySaverAutoEnabledPowerSaverOn =>
      'Auto-enabled — device power saver on';

  @override
  String batterySaverAutoEnablesAt(int threshold) {
    return 'Auto-enables at $threshold% battery or below';
  }

  @override
  String get batterySaverReducesPolling =>
      'Reduces polling and background activity';

  @override
  String get batterySaving => 'Battery saving';

  @override
  String get biometricsNotSupportedOnThisPlatform =>
      'Biometrics not supported on this platform';

  @override
  String get block => 'Block';

  @override
  String get blockContact => 'Block contact';

  @override
  String get blockContactBody => 'They won\'t be able to message you.';

  @override
  String get blockContactQuestion => 'Block contact?';

  @override
  String get blocked => 'Blocked';

  @override
  String get blockedContacts => 'Blocked contacts';

  @override
  String get blockedViewProfile => 'Blocked · View profile';

  @override
  String get bugFindingFeatureSuggestions =>
      'Bug finding & Feature suggestions';

  @override
  String get builtOnTor => 'Built on Tor';

  @override
  String get caches => 'Caches';

  @override
  String get cachesCleared => 'Caches cleared';

  @override
  String get calculating => 'Calculating…';

  @override
  String get callHistory => 'Call History';

  @override
  String get callMicrophone => 'Call microphone';

  @override
  String get callPreview => '📞 Call';

  @override
  String get cameraPermissionRequired => 'Camera Permission Required';

  @override
  String get cancel => 'Cancel';

  @override
  String get cancelMessage => 'Cancel message';

  @override
  String get cancelScheduledMessage => 'Cancel scheduled message?';

  @override
  String get changePanicPin => 'Change panic PIN';

  @override
  String get changePasscode => 'Change passcode';

  @override
  String get changeUnlockMethodInSettingsPrivacy =>
      'Change unlock method anytime in Settings → Privacy';

  @override
  String get chatMedia => 'Chat Media';

  @override
  String get chatMedia2 => 'Chat media';

  @override
  String get chatMediaIsStoredEncryptedOnThisDevice =>
      'Chat media is stored encrypted on this device. ';

  @override
  String get chatMediaStoredEncryptedDisclaimer =>
      'Chat media is stored encrypted on this device. Deleting media here removes it locally only — it may still exist for other participants.';

  @override
  String get chatWithMyself => 'Chat with myself';

  @override
  String get chatWithMyself6 => 'chat with myself';

  @override
  String get chats => 'Chats';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get checking => 'Checking...';

  @override
  String get chooseANew6DigitPin => 'Choose a new 6-digit PIN.';

  @override
  String get chooseANewPassphraseAtLeast12Characters =>
      'Choose a new passphrase (at least 12 characters).';

  @override
  String get chooseAStrongPasswordToEncryptYourBackup =>
      'Choose a strong password to encrypt your backup. ';

  @override
  String get chooseDownloadFolder => 'Choose download folder';

  @override
  String get chooseFolder => 'Choose folder';

  @override
  String get chooseYourUnlockMethod => 'Choose your unlock method';

  @override
  String get clear => 'Clear';

  @override
  String get clearCaches => 'Clear caches';

  @override
  String get clearCallHistory => 'Clear call history';

  @override
  String get clearHistory => 'Clear history';

  @override
  String get close => 'Close';

  @override
  String get closeSearch => 'Close search';

  @override
  String get comingSoonNotWorking => 'COMING SOON, NOT WORKING';

  @override
  String get completed => 'Completed';

  @override
  String get composerRounding => 'Composer rounding';

  @override
  String get confirm => 'Confirm';

  @override
  String get confirmNewPanicPin => 'Confirm new panic PIN';

  @override
  String get confirmNewPin => 'Confirm new PIN';

  @override
  String get confirmPanicPin => 'Confirm panic PIN';

  @override
  String get confirmPasscode => 'Confirm Passcode';

  @override
  String get confirmPassphrase => 'Confirm Passphrase';

  @override
  String get confirmYourPin => 'Confirm your PIN';

  @override
  String get connectToTorBeforeAddingContacts =>
      'Connect to Tor before adding contacts';

  @override
  String get connectTor => 'Connect Tor';

  @override
  String get connectTorForPrysmId => 'Connect Tor for Prysm ID';

  @override
  String get connectViaOnionId => 'Connect via onion ID';

  @override
  String get connected => 'Connected';

  @override
  String get connecting => 'Connecting...';

  @override
  String get connecting2 => 'Connecting…';

  @override
  String get connecting3 => 'Connecting…';

  @override
  String get connecting4 => 'Connecting';

  @override
  String connectingBootstrap(String bootstrap) {
    return 'connecting ($bootstrap%)';
  }

  @override
  String get connectingToTor => 'Connecting to Tor…';

  @override
  String get contactAdded => 'Contact added';

  @override
  String get contactAddedSuccessfully => 'Contact added successfully';

  @override
  String contactCountSummary(int contactCount, int groupCount) {
    String _temp0 = intl.Intl.pluralLogic(
      contactCount,
      locale: localeName,
      other: '$contactCount contacts',
      one: '1 contact',
    );
    String _temp1 = intl.Intl.pluralLogic(
      groupCount,
      locale: localeName,
      other: '$groupCount groups',
      one: '1 group',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String get contactInfo => 'Contact Info';

  @override
  String get contactNotFound => 'Contact not found';

  @override
  String get continueLabel => 'Continue';

  @override
  String get continueOffline => 'Continue offline';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get copy => 'Copy';

  @override
  String get copyId => 'Copy ID';

  @override
  String get couldNotAddContact => 'Could not add contact';

  @override
  String get couldNotChangeUnlockMethod => 'Could not change unlock method';

  @override
  String get couldNotConnectToPeerMessagesWillBe =>
      'Could not connect to peer. Messages will be queued.';

  @override
  String get couldNotCopy => 'Could not copy';

  @override
  String get couldNotCreateGroupMakeSureAllMembers =>
      'Could not create group. Make sure all members are online and try again.';

  @override
  String couldNotDeleteFileE(String e) {
    return 'Could not delete file: $e';
  }

  @override
  String get couldNotDeleteForEveryone => 'Could not delete for everyone';

  @override
  String couldNotDeleteMediaE(String e) {
    return 'Could not delete media: $e';
  }

  @override
  String get couldNotEditMessage => 'Could not edit message';

  @override
  String couldNotLoadDownloadsE(String e) {
    return 'Could not load downloads: $e';
  }

  @override
  String get couldNotLoadImage => 'Could not load image';

  @override
  String couldNotLoadMediaE(String e) {
    return 'Could not load media: $e';
  }

  @override
  String get couldNotLoadPreview => 'Could not load preview';

  @override
  String couldNotLoadStorageUsageE(String e) {
    return 'Could not load storage usage: $e';
  }

  @override
  String couldNotOpenFileE(String e) {
    return 'Could not open file: $e';
  }

  @override
  String couldNotOpenImageE(String e) {
    return 'Could not open image: $e';
  }

  @override
  String couldNotOpenSeparateWindowE(String e) {
    return 'Could not open separate window: $e';
  }

  @override
  String couldNotOpenVideoE(String e) {
    return 'Could not open video: $e';
  }

  @override
  String couldNotPlayVoiceMessageE(String e) {
    return 'Could not play voice message: $e';
  }

  @override
  String couldNotReadDroppedFileE(String e) {
    return 'Could not read dropped file: $e';
  }

  @override
  String couldNotReadFileE(String e) {
    return 'Could not read file: $e';
  }

  @override
  String get couldNotReadPresentationContentInPrysm =>
      'Could not read presentation content in Prysm.';

  @override
  String get couldNotReadSpreadsheet => 'Could not read spreadsheet';

  @override
  String couldNotSaveImage(String e) {
    return 'Could not save image: $e';
  }

  @override
  String couldNotScheduleMessageE(String e) {
    return 'Could not schedule message: $e';
  }

  @override
  String get couldNotSendFileGroupKeyUnavailable =>
      'Could not send file — group key unavailable';

  @override
  String get couldNotSendMessageGroupKeyUnavailable =>
      'Could not send message — group key unavailable';

  @override
  String get couldNotSetUpPasscodeTryAgain =>
      'Could not set up passcode. Try again.';

  @override
  String get couldNotSetUpPassphraseMin12 =>
      'Could not set up passphrase. Use at least 12 characters.';

  @override
  String get couldNotSetUpPinTryAgain => 'Could not set up PIN. Try again.';

  @override
  String couldNotStartCallE(String e) {
    return 'Could not start call: $e';
  }

  @override
  String get couldNotUpdateUnlockCode => 'Could not update unlock code';

  @override
  String count(String count) {
    return '$count';
  }

  @override
  String get create => 'Create';

  @override
  String get createAnotherBackup => 'Create another backup';

  @override
  String get createBackup => 'Create Backup';

  @override
  String get createBackupNow => 'Create backup now';

  @override
  String get createGroup => 'Create Group';

  @override
  String get createGroup2 => 'Create group';

  @override
  String get createPassphrase => 'Create Passphrase';

  @override
  String get createYourPin => 'Create your PIN';

  @override
  String get cryptoUpgradeRequired => 'Crypto upgrade required';

  @override
  String get currentPanicPin => 'Current panic PIN';

  @override
  String get currentPassphrase => 'Current passphrase';

  @override
  String get currentPin => 'Current PIN';

  @override
  String get cut => 'Cut';

  @override
  String get cyanMode => 'Cyan Mode';

  @override
  String dMoYHMin(String d, String mo, String y, String h, String min) {
    return '$d/$mo/$y - $h:$min';
  }

  @override
  String get dangerZone => 'Danger Zone';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get data => 'Data';

  @override
  String get debugOptions => 'Debug options';

  @override
  String get decline => 'Decline';

  @override
  String get declineCall => 'Decline call';

  @override
  String get declined => 'Declined';

  @override
  String get decoyProfile => 'Decoy profile';

  @override
  String get defaultInput => 'Default input';

  @override
  String get delete => 'Delete';

  @override
  String get deleteAllMessagesInThisChat => 'Delete all messages in this chat';

  @override
  String get deleteChat => 'Delete Chat';

  @override
  String get deleteContact => 'Delete Contact';

  @override
  String get deleteFile => 'Delete file';

  @override
  String deleteFileFromDownloads(String fileName) {
    return 'Delete \"$fileName\" from downloads?';
  }

  @override
  String get deleteForEveryone => 'Delete for everyone';

  @override
  String get deleteGroup => 'Delete group';

  @override
  String get deleteMedia => 'Delete media';

  @override
  String get deleteTemporaryImageAndVoiceCaches =>
      'Delete temporary image and voice caches? ';

  @override
  String get deleteThisContactFromYourListCannotBe =>
      'Delete this contact from your list. Cannot be undone.';

  @override
  String get deleteThisGroupForEveryoneThisCannotBe =>
      'Delete this group for everyone? This cannot be undone.';

  @override
  String get deleted => 'Deleted';

  @override
  String get delivered => 'Delivered';

  @override
  String get delivery => 'Delivery';

  @override
  String get destroyKeysAndLocalDatabasesThenShowAn =>
      'Destroy keys and local databases, then show an empty app';

  @override
  String directionCallDuration(String direction, String duration) {
    return '$direction call · $duration';
  }

  @override
  String directionCallStatus(String direction, String status) {
    return '$direction call · $status';
  }

  @override
  String get disappearing1d => '1 day';

  @override
  String get disappearing1h => '1 hour';

  @override
  String get disappearing1w => '1 week';

  @override
  String get disappearing30s => '30 seconds';

  @override
  String get disappearing4w => '4 weeks';

  @override
  String get disappearing5m => '5 minutes';

  @override
  String get disappearing8h => '8 hours';

  @override
  String disappearingDurationDays(int count) {
    return '${count}d';
  }

  @override
  String disappearingDurationHours(int count) {
    return '${count}h';
  }

  @override
  String disappearingDurationMinutes(int count) {
    return '${count}m';
  }

  @override
  String disappearingDurationSeconds(int count) {
    return '${count}s';
  }

  @override
  String disappearingDurationWeeks(int count) {
    return '${count}w';
  }

  @override
  String get disappearingMessages => 'Disappearing messages';

  @override
  String get disappearingOff => 'Off';

  @override
  String get disappearsAfterViewing => '🔒 Disappears after viewing';

  @override
  String get discard => 'Discard';

  @override
  String get discardInvite => 'Discard invite';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get diskUsageAndMediaManagement => 'Disk usage and media management';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get displayName => 'Display Name';

  @override
  String get displayName2 => 'Display name';

  @override
  String get done => 'Done';

  @override
  String get download => 'Download';

  @override
  String get downloadAnyway => 'Download anyway';

  @override
  String downloadFailedE(String e) {
    return 'Download failed: $e';
  }

  @override
  String get downloadFromGithubReleases => 'Download from GitHub releases';

  @override
  String get downloadLocation => 'Download Location';

  @override
  String get downloadLocationResetToDefault =>
      'Download location reset to default';

  @override
  String get downloadRiskyFile => 'Download risky file?';

  @override
  String get downloading => 'Downloading…';

  @override
  String get downloads => 'Downloads';

  @override
  String get downloadsFolderNotAvailable => 'Downloads folder not available';

  @override
  String downloadsWillBeSavedToPath(String path) {
    return 'Downloads will be saved to $path';
  }

  @override
  String get dropToSend => 'Drop to send';

  @override
  String get edit => 'Edit';

  @override
  String get editMessage => 'Edit message';

  @override
  String get editName => 'Edit Name';

  @override
  String get emergency => 'Emergency';

  @override
  String get emptyFile => 'Empty file';

  @override
  String get enableRelayServer => 'Enable Relay Server';

  @override
  String get encryptionPrivacy => 'Encryption & Privacy';

  @override
  String get endToEndEncryption => '• End-to-end encryption';

  @override
  String get enterAGroupName => 'Enter a group name';

  @override
  String get enterAValidBase58PrysmId => 'Enter a valid Base58 Prysm ID';

  @override
  String get enterBothIdAndDisplayName => 'Enter both ID and display name';

  @override
  String get enterPanicPinToRemove => 'Enter panic PIN to remove';

  @override
  String get enterPasscode => 'Enter Passcode';

  @override
  String get enterPassphrase => 'Enter Passphrase';

  @override
  String get enterPassphraseOrPanicPin => 'Enter passphrase or panic PIN';

  @override
  String get enterYourCurrentUnlockPassphrase =>
      'Enter your current unlock passphrase.';

  @override
  String get enterYourCurrentUnlockPin => 'Enter your current unlock PIN.';

  @override
  String get export => 'Export';

  @override
  String get exportEncryptedBackupFile => 'Export encrypted backup file';

  @override
  String get exportLog => 'Export Log';

  @override
  String get failed => 'Failed';

  @override
  String failedToCreateGroupE(String e) {
    return 'Failed to create group: $e';
  }

  @override
  String failedToExportLog(String e) {
    return 'Failed to export log: $e';
  }

  @override
  String failedToExportLogE(String e) {
    return 'Failed to export log: $e';
  }

  @override
  String get failedToPlayVoiceMessage => 'Failed to play voice message';

  @override
  String get failedToRefreshCircuit => 'Failed to refresh circuit';

  @override
  String get features => 'Features:';

  @override
  String get file => 'File';

  @override
  String get fileDeleted => 'File deleted';

  @override
  String get fileIsStillDecryptingOrEmpty =>
      'File is still decrypting or empty';

  @override
  String fileMayBeHarmfulOnlyDownloadIfTrusted(String fileName) {
    return '$fileName may be harmful to your device. Only download if you trust the sender.';
  }

  @override
  String get fileNotReadyToDownload => 'File not ready to download';

  @override
  String get filePreview => '📎 File';

  @override
  String get filePreviews => 'File previews';

  @override
  String get filePreviewsInChatSubtitle =>
      'Show inline previews for documents, images, and media in chat';

  @override
  String get filePreviewsSubtitle =>
      'Show inline previews for images and documents';

  @override
  String get fileQueuedWillSendWhenPeerIsAvailable =>
      'File queued. Will send when peer is available.';

  @override
  String get fileTooLargeToPreview => 'File too large to preview';

  @override
  String filenameMayBeHarmfulToYourDevice(String fileName) {
    return '$fileName may be harmful to your device. ';
  }

  @override
  String get fingerprint => 'Fingerprint';

  @override
  String get fingerprintCopied => 'Fingerprint copied';

  @override
  String get font => 'Font';

  @override
  String get fontIbmPlexSans => 'IBM Plex Sans';

  @override
  String get fontInter => 'Inter';

  @override
  String get fontJetBrainsMono => 'JetBrains Mono';

  @override
  String get fontSystem => 'System';

  @override
  String get galleryAccessDenied => 'Gallery access denied';

  @override
  String get general => 'General';

  @override
  String get getStarted => 'Get started';

  @override
  String get gettingStarted => 'Getting started';

  @override
  String get goOnlineToSendAndReceiveMessages =>
      'Go online to send and receive messages';

  @override
  String get group => 'Group';

  @override
  String get groupChat => 'Group chat';

  @override
  String get groupInviteContactsOnlyDescription =>
      'Invites from anyone else are discarded the moment they arrive: nothing is stored, nothing is shown.';

  @override
  String get groupInviteContactsOnlyTitle =>
      'Only accept invites from contacts';

  @override
  String get groupInviteHoldDescription =>
      'An invite from someone who is not in your contacts is kept as a request. Your device never contacts them, and adding them as a contact is what applies the invite.';

  @override
  String get groupInviteHoldTitle => 'Hold invites from unknown senders';

  @override
  String get groupInvites => 'Group invites';

  @override
  String groupIsFullMax(String max) {
    return 'Group is full ($max members max)';
  }

  @override
  String groupIsFullMaxgroupmembersMembersMax(String maxGroupMembers) {
    return 'Group is full ($maxGroupMembers members max)';
  }

  @override
  String get groupName => 'Group name';

  @override
  String get groupPhotoUpdated => 'Group photo updated';

  @override
  String get groupRenamed => 'Group renamed';

  @override
  String get hangUp => 'Hang up';

  @override
  String get healthCheck => 'Health check: ';

  @override
  String get healthCheckLabel => 'Health check:';

  @override
  String get helpSupport => 'Help & Support';

  @override
  String get hideEmojiPicker => 'Hide emoji picker';

  @override
  String get hideToTrayWhenClickingMinimize =>
      'Hide to tray when clicking the minimize button';

  @override
  String get holdInvitesFromUnknownSenders =>
      'Hold invites from unknown senders';

  @override
  String get holdToRecordAVoiceMessage => 'Hold to record a voice message';

  @override
  String hourMinutePeriod(String hour, String minute, String period) {
    return '$hour:$minute $period';
  }

  @override
  String get idCopiedToClipboard => 'ID copied to clipboard';

  @override
  String get idNotAvailable => 'ID not available';

  @override
  String get identityVerification => 'Identity verification';

  @override
  String get identityVerified => 'Identity verified';

  @override
  String get image => '📷 Image';

  @override
  String get imageNotReadyToSave => 'Image not ready to save';

  @override
  String imageSavedFileName(String fileName) {
    return 'Image saved ($fileName)';
  }

  @override
  String get importFromBackupFile => 'Import from backup file';

  @override
  String get inAppPdfPreviewIsNotAvailableOn =>
      'In-app PDF preview is not available on this platform.';

  @override
  String get inCall => 'In call';

  @override
  String get incoming => 'Incoming';

  @override
  String get incomingCall => 'Incoming call';

  @override
  String get incomingCalls => 'Incoming Calls';

  @override
  String get incomingCallsChannel => 'Incoming Calls';

  @override
  String get incomingCallsChannelDescription => 'Ringing incoming voice calls';

  @override
  String get incorrectPanicPin => 'Incorrect panic PIN';

  @override
  String get incorrectPassphrase => 'Incorrect passphrase';

  @override
  String get incorrectPin => 'Incorrect PIN';

  @override
  String get info => 'Info';

  @override
  String get installPermissionRequired => 'Install permission required';

  @override
  String get invalidQrCode => 'Invalid QR code';

  @override
  String get inviteRequests => 'Invite requests';

  @override
  String get invitesFromAnyoneElseAreDiscardedTheMoment =>
      'Invites from anyone else are discarded the moment they arrive: ';

  @override
  String get iosCameraUsage =>
      'Prysm needs camera access to scan QR codes and add contacts.';

  @override
  String get iosMicrophoneUsage =>
      'Prysm needs microphone access for voice messages and calls.';

  @override
  String get iosPhotoLibraryAddUsage =>
      'Prysm needs access to save images to your photo library.';

  @override
  String get iosPhotoLibraryUsage =>
      'Prysm needs access to your photo library when you share images into the app.';

  @override
  String get itWillNotBeSent => 'It will not be sent.';

  @override
  String get keep => 'Keep';

  @override
  String get keepPrysmRunningInTrayWhenClosing =>
      'Keep Prysm running in the tray when closing the window';

  @override
  String get keyChangedReVerify => 'Key changed — re-verify';

  @override
  String labelModKey(String label, String mod, String key) {
    return '$label ($mod+$key)';
  }

  @override
  String get language => 'Language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageItalian => 'Italiano';

  @override
  String get languageSystem => 'System';

  @override
  String get lastIssue => 'Last issue: ';

  @override
  String get lastSeen => 'Last Seen';

  @override
  String get later => 'Later';

  @override
  String get leadDeveloper => 'Lead Developer';

  @override
  String get leaveAction => 'Leave';

  @override
  String get leaveGroup => 'Leave group';

  @override
  String get leaveThisGroup => 'Leave this group?';

  @override
  String get legal => 'Legal';

  @override
  String get lightMode => 'Light Mode';

  @override
  String get linkCopied => 'Link copied';

  @override
  String get linkPreviews => 'Link previews';

  @override
  String get linkPreviewsSubtitle => 'Fetch link metadata when you send URLs';

  @override
  String get linkPreviewsViaTorSubtitle =>
      'Fetch titles and images for URLs in messages via Tor';

  @override
  String get loading => 'Loading...';

  @override
  String get localDataError => 'Local data error';

  @override
  String logSavedTo(String path) {
    return 'Log saved to $path';
  }

  @override
  String get lookUp => 'Look up';

  @override
  String get lookingUpContactOnTor => 'Looking up contact on Tor...';

  @override
  String get losePassphraseOnlyBackupRestores =>
      'If you lose your passphrase, only a backup can restore your account';

  @override
  String get losePinOnlyBackupRestores =>
      'If you lose your PIN, only a backup can restore your account';

  @override
  String get markAsVerified => 'Mark as verified';

  @override
  String get markVerified => 'Mark verified';

  @override
  String maxMaxgroupmembersMembersTotal(String maxGroupMembers) {
    return 'Max $maxGroupMembers members total';
  }

  @override
  String get mediaDeleted => 'Media deleted';

  @override
  String get member => 'Member';

  @override
  String memberDisplayNameWithYou(String name, String youLabel) {
    return '$name ($youLabel)';
  }

  @override
  String membersCount(String count, String max) {
    return '$count / $max members';
  }

  @override
  String get messageBubbleRounding => 'Message bubble rounding';

  @override
  String get messageHint => 'Message';

  @override
  String get messageInfo => 'Message info';

  @override
  String get messageNotFoundInLoadedHistory =>
      'Message not found in loaded history';

  @override
  String get messageQueuedWillSendWhenMembersAreReachable =>
      'Message queued. Will send when members are reachable.';

  @override
  String get messageQueuedWillSendWhenPeerIsAvailable =>
      'Message queued. Will send when peer is available.';

  @override
  String get messageShadows => 'Message shadows';

  @override
  String get messages => 'Messages';

  @override
  String get microphoneLevel => 'Microphone level';

  @override
  String get microphonePermissionDenied => 'Microphone permission denied';

  @override
  String get minimizeToSystemTrayOnClose => 'Minimize to system tray on close';

  @override
  String get minimizeToTrayOnClose => 'Minimize to tray on close';

  @override
  String get minimizeToTrayOnCloseSubtitle =>
      'Keep Prysm running in the background when you close the window';

  @override
  String get minimizeToTrayWhenMinimizingWindow =>
      'Minimize to tray when minimizing window';

  @override
  String get minimum12Characters => 'Minimum 12 characters';

  @override
  String minutesSeconds(String minutes, String seconds) {
    return '$minutes:$seconds';
  }

  @override
  String get missed => 'Missed';

  @override
  String get mockUpdateUiNoDownload => 'Mock update UI (no download)';

  @override
  String get moreReactions => 'More reactions…';

  @override
  String mustBeAtLeastNCharacters(int minLength) {
    return 'Must be at least $minLength characters';
  }

  @override
  String get muteNotifications => 'Mute notifications';

  @override
  String get muted => 'Muted';

  @override
  String mutedForDuration(String duration) {
    return 'for $duration';
  }

  @override
  String mutedUntilDateAndTime(String date, String time) {
    return 'Muted until $date, $time';
  }

  @override
  String mutedUntilTime(String time) {
    return 'Muted until $time';
  }

  @override
  String get mutedUntilYouTurnNotificationsBackOn =>
      'Muted until you turn notifications back on';

  @override
  String get myQrCode => 'My QR Code';

  @override
  String get needsAttention => 'Needs attention';

  @override
  String get network => 'Network';

  @override
  String get neverSharePassphrase => 'Never share your passphrase with anyone';

  @override
  String get neverSharePin => 'Never share your PIN with anyone';

  @override
  String get newCircuit => 'New circuit';

  @override
  String get newMessage => 'New message';

  @override
  String get newMessagesChannel => 'New Messages';

  @override
  String get newMessagesChannelDescription =>
      'Notification channel for new messages';

  @override
  String get newPanicPin => 'New panic PIN';

  @override
  String get newPassphrase => 'New passphrase';

  @override
  String get newPassphraseMustBeDifferent => 'New passphrase must be different';

  @override
  String get newPin => 'New PIN';

  @override
  String get newPinMustBeDifferent => 'New PIN must be different';

  @override
  String get newTorCircuitRequested => 'New Tor circuit requested';

  @override
  String get next => 'Next';

  @override
  String get nextMatch => 'Next match';

  @override
  String nextScheduleLabel(String label) {
    return 'Next: $label';
  }

  @override
  String get no => 'No';

  @override
  String noBackupFilesFoundInLocation(String location) {
    return 'No backup files found in $location';
  }

  @override
  String get noBlockedContacts => 'No blocked contacts';

  @override
  String get noCallsYet => 'No calls yet';

  @override
  String get noCentralServers => '• No central servers';

  @override
  String get noContactsAvailableToAdd => 'No contacts available to add';

  @override
  String get noConversationsFound => 'No conversations found';

  @override
  String get noDownloadedFiles => 'No downloaded files';

  @override
  String get noEmojiFound => 'No emoji found';

  @override
  String get noForgotPassphraseRecovery =>
      'There is no \"forgot passphrase\" recovery';

  @override
  String get noForgotPinRecovery => 'There is no \"forgot PIN\" recovery';

  @override
  String get noIdentityKeyIsStoredForThisContact =>
      'No identity key is stored for this contact yet.';

  @override
  String get noInviteRequests => 'No invite requests';

  @override
  String get noLogFileFound => 'No log file found';

  @override
  String get noMediaInThisConversationYet =>
      'No media in this conversation yet';

  @override
  String get noMediaStored => 'No media stored';

  @override
  String get noPreviewAvailable => 'No preview available';

  @override
  String get noReadInformationAvailable => 'No read information available.';

  @override
  String get notVerified => 'Not verified';

  @override
  String get notesToSelf => 'Notes to self';

  @override
  String get notesToYourself => 'Notes to yourself';

  @override
  String get notifications => 'Notifications';

  @override
  String notificationsEnabledForLabel(String label) {
    return 'Notifications enabled for $label';
  }

  @override
  String get notificationsMuted => 'Notifications muted';

  @override
  String notificationsMutedMuteduntilForLabel(String mutedUntil, String label) {
    return 'Notifications muted $mutedUntil for $label';
  }

  @override
  String get notificationsSubtitle => 'Show alerts for new messages and calls';

  @override
  String get offline => 'Offline';

  @override
  String get offlineConnectLaterForPrysmId =>
      'Offline — connect later to get your Prysm ID';

  @override
  String get offlinePrysmOrRetry =>
      'You can use Prysm offline or retry when you have a connection.';

  @override
  String get ok => 'OK';

  @override
  String get onboardingIdBody =>
      'This is your unique address on Tor. Friends use it to add you. It is a Base58 encoding of your .onion hidden service address.';

  @override
  String get onboardingIdShareHint =>
      'Share this ID or QR so others can message you. You can always find it in your profile or the sidebar.';

  @override
  String onboardingStepOf(String current, String total) {
    return 'Step $current of $total';
  }

  @override
  String get onboardingTorBody =>
      'Prysm routes all traffic through the Tor network. Your messages reach contacts directly — no central server stores your chats.';

  @override
  String get onboardingTorBulletMustConnect =>
      'Tor must be connected before you can message anyone';

  @override
  String get onboardingTorBulletOnionAddress =>
      'Your onion address is your identity on the network';

  @override
  String get onboardingTorBulletStatusBar =>
      'The Tor status in the app bar shows your connection';

  @override
  String get onboardingWelcomeSetupRequired =>
      'Choose how you unlock Prysm and protect your keys. This setup is required before you can use the app.';

  @override
  String get onboardingWelcomeTour =>
      'Private messaging over Tor. This short tour covers the essentials so you can start chatting confidently.';

  @override
  String onionAddress(String address) {
    return 'Onion: $address';
  }

  @override
  String get online => 'Online';

  @override
  String get onlyAcceptInvitesFromContacts =>
      'Only accept invites from contacts';

  @override
  String get onlyDownloadIfYouTrustTheSender =>
      'Only download if you trust the sender.';

  @override
  String get onlyMarkContactVerifiedIfComparedFull =>
      'Only mark this contact as verified if you compared their fingerprint in person or over a trusted channel.';

  @override
  String get onlyMarkThisContactAsVerifiedIfYou =>
      'Only mark this contact as verified if you compared their ';

  @override
  String get onlyOneFileAtATime => 'Only one file at a time';

  @override
  String get openInASeparateWindow => 'Open in a separate window';

  @override
  String get openMenu => 'Open menu';

  @override
  String get openNotification => 'Open notification';

  @override
  String get openSettings => 'Open Settings';

  @override
  String get openSettingsToAllowInstalls =>
      'Open Settings to allow Prysm to install updates.';

  @override
  String get openSource => '• Open source';

  @override
  String get openToViewTheMessage => 'Open to view the message';

  @override
  String get openWithSystemPlayer => 'Open with system player';

  @override
  String get opened => 'Opened';

  @override
  String get opening => 'Opening…';

  @override
  String get orangeMode => 'Orange Mode';

  @override
  String get originalMessageUnavailable => 'Original message unavailable';

  @override
  String get otherAppData => 'Other app data';

  @override
  String get outboundQueueDepth => 'Outbound queue depth: ';

  @override
  String get outboundQueueDepthLabel => 'Outbound queue depth:';

  @override
  String get outgoing => 'Outgoing';

  @override
  String get panicDecoyDescription =>
      'Show an empty app while your real data stays encrypted on disk';

  @override
  String get panicDecoyTitle => 'Decoy profile';

  @override
  String get panicMode => 'Panic mode';

  @override
  String get panicPinCannotMatchYourMainPasscode =>
      'Panic PIN cannot match your main passcode';

  @override
  String get panicPinConfigured => 'Panic PIN configured';

  @override
  String get panicPinExplanationBody =>
      'A panic PIN is a second passcode. Entering it at unlock never reveals your real chats. Configure what happens when it is used.';

  @override
  String get panicPinIsSet => 'Panic PIN is set';

  @override
  String get panicPinNotSet => 'Panic PIN not set';

  @override
  String get panicPinRemoved => 'Panic PIN removed';

  @override
  String get panicPinSaved => 'Panic PIN saved';

  @override
  String get panicPinUpdated => 'Panic PIN updated';

  @override
  String get panicWipeDescription =>
      'Destroy keys and local databases, then show an empty app';

  @override
  String get panicWipeTitle => 'Wipe local keys';

  @override
  String get passphrase => 'Passphrase';

  @override
  String get passphrase12Characters => 'Passphrase (12+ characters)';

  @override
  String get passphraseCannotMatchYourPanicPin =>
      'Passphrase cannot match your panic PIN';

  @override
  String get passphraseEncryptsKeysBody =>
      'Your passphrase encrypts your private keys on this device — Prysm never sees or stores it in the cloud.';

  @override
  String get passphraseMustBeAtLeast12Characters =>
      'Passphrase must be at least 12 characters';

  @override
  String get passphraseUpdated => 'Passphrase updated';

  @override
  String get passphrasesDoNotMatch => 'Passphrases do not match';

  @override
  String get passwordMustBeAtLeast4Characters =>
      'Password must be at least 4 characters';

  @override
  String get paste => 'Paste';

  @override
  String get pdfDocument => 'PDF document';

  @override
  String get peerIsMuted => 'Peer is muted';

  @override
  String get pending => 'Pending';

  @override
  String personIsTyping(String name) {
    return '$name is typing…';
  }

  @override
  String get photo => 'Photo';

  @override
  String get photoDisappearsAfterTheRecipientOpensIt =>
      'Photo disappears after the recipient opens it';

  @override
  String get photoPreview => '📷 Photo';

  @override
  String get pickAConversationFromTheSidebarOrStart =>
      'Pick a conversation from the sidebar or start a new one.';

  @override
  String get pickConversationFromSidebar =>
      'Pick a conversation from the sidebar or start a new one.';

  @override
  String get pickOneMethodYouCanChangeItLater =>
      'Pick one method. You can change it later in Settings.';

  @override
  String get pinCannotMatchYourPanicPin => 'PIN cannot match your panic PIN';

  @override
  String get pinChat => 'Pin chat';

  @override
  String get pinEncryptsKeysBody =>
      'Your 6-digit PIN encrypts your private keys on this device — Prysm never sees or stores it in the cloud.';

  @override
  String get pinMustBe6Digits => 'PIN must be 6 digits';

  @override
  String get pinUpdated => 'PIN updated';

  @override
  String get pinkMode => 'Pink Mode';

  @override
  String get pinsDoNotMatch => 'PINs don\'t match';

  @override
  String get presentation => 'Presentation';

  @override
  String get previewUnavailable => 'Preview unavailable';

  @override
  String get previewUnavailableFileTooLarge =>
      'Preview unavailable (file too large)';

  @override
  String get previewUpdateDialog => 'Preview update dialog';

  @override
  String get previousMatch => 'Previous match';

  @override
  String get privacy => 'Privacy';

  @override
  String get privacyInformation => 'Privacy Information';

  @override
  String get privacySettings => 'Privacy Settings';

  @override
  String privacySettingsBody(String appName) {
    return 'These settings help you control your privacy on $appName. Your choices will be applied across all your conversations.';
  }

  @override
  String get profile => 'Profile';

  @override
  String get profilePhoto => 'Profile Photo';

  @override
  String get prysm03UsesNewEndToEnd =>
      'Prysm 0.3 uses new end-to-end encryption (Curve25519 + AEAD). ';

  @override
  String get prysmCouldNotOpenItsLocalDatabaseThis =>
      'Prysm could not open its local database. This can happen after ';

  @override
  String get prysmIdBase58Label => 'Prysm ID (Base58)';

  @override
  String get prysmIdCopied => 'Prysm ID copied';

  @override
  String get prysmIdCopiedToClipboard => 'Prysm ID copied to clipboard';

  @override
  String get prysmIdHintExample => 'eg. 51EsbujFRDJLHJ';

  @override
  String get prysmNeedsCameraAccessToScanQrCodes =>
      'Prysm needs camera access to scan QR codes for adding contacts.';

  @override
  String get purpleMode => 'Purple Mode';

  @override
  String get qrScanCompareFingerprintManually =>
      'QR scanning is only supported on mobile devices. Compare the fingerprint manually and use \"Mark as verified\".';

  @override
  String get qrScanner => 'QR Scanner';

  @override
  String get qrScannerIsOnlySupportedOnMobileDevices =>
      'QR Scanner is only supported on mobile devices (Android/iOS).';

  @override
  String get qrScanningIsOnlySupportedOnMobileDevices =>
      'QR scanning is only supported on mobile devices. ';

  @override
  String get quit => 'Quit';

  @override
  String get read => 'Read';

  @override
  String get readBy => 'Read by';

  @override
  String get readReceipts => 'Read Receipts';

  @override
  String get receivedPreview => 'Received preview';

  @override
  String get recentTorLog => 'Recent Tor log';

  @override
  String get recording => 'Recording...';

  @override
  String get refreshTorCircuit => 'Refresh Tor Circuit';

  @override
  String get refuseMessagesFromNonContacts =>
      'Refuse messages from non-contacts';

  @override
  String get refuseNonContactsSubtitle =>
      'When enabled, people who are not in your contacts cannot message you directly.';

  @override
  String get remove => 'Remove';

  @override
  String get removeMember => 'Remove member';

  @override
  String removeMemberFromGroupQuestion(String name) {
    return 'Remove $name from the group?';
  }

  @override
  String get removePanicPin => 'Remove panic PIN';

  @override
  String get removeVerification => 'Remove verification';

  @override
  String get renameGroup => 'Rename group';

  @override
  String get replayTheSetupTour => 'Replay the setup tour';

  @override
  String get reply => 'Reply';

  @override
  String get requestANewCircuitWhenConnectionsAreStuck =>
      'Request a new circuit when connections are stuck';

  @override
  String requestCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count requests',
      one: '1 request',
    );
    return '$_temp0';
  }

  @override
  String get reset => 'Reset';

  @override
  String get resetAllSettings => 'Reset All Settings?';

  @override
  String get resetLocalDataAndContinue => 'Reset local data and continue';

  @override
  String get resetSettings => 'Reset Settings';

  @override
  String get restartTor => 'Restart Tor';

  @override
  String get restore => 'Restore';

  @override
  String get restoreBackup => 'Restore Backup';

  @override
  String get restoreDefaultSettings => 'Restore default settings';

  @override
  String restoreFailedE(String e) {
    return 'Restore failed: $e';
  }

  @override
  String get restoreFailedWrongPasswordOrCorruptFile =>
      'Restore failed — wrong password or corrupt file';

  @override
  String get retry => 'Retry';

  @override
  String get ringing => 'Ringing...';

  @override
  String get save => 'Save';

  @override
  String get saveDebugLogToDownloads => 'Save debug log to download folder';

  @override
  String get saveImage => 'Save image';

  @override
  String get savePassphrase => 'Save passphrase';

  @override
  String savedFileName(String fileName) {
    return 'Saved $fileName';
  }

  @override
  String get savedToGallery => 'Saved to gallery';

  @override
  String get savedToPhotos => 'Saved to Photos';

  @override
  String get scanContactQr => 'Scan Contact QR';

  @override
  String get scanNotAvailable => 'Scan not available';

  @override
  String get scanQr => 'Scan QR';

  @override
  String get scanQrCode => 'Scan QR code';

  @override
  String get scanText => 'Scan text';

  @override
  String get scannedQrDoesNotMatchContact =>
      'The scanned QR code does not match this contact\'s identity. This may indicate impersonation.';

  @override
  String get schedule => 'Schedule';

  @override
  String scheduleDateAt(String date, String time) {
    return '$date at $time';
  }

  @override
  String get scheduleMessage => 'Schedule message';

  @override
  String scheduleTodayAt(String time) {
    return 'Today at $time';
  }

  @override
  String scheduleTomorrowAt(String time) {
    return 'Tomorrow at $time';
  }

  @override
  String scheduleWeekdayAt(String weekday, String time) {
    return '$weekday at $time';
  }

  @override
  String get scheduledMessageCancelled => 'Scheduled message cancelled';

  @override
  String get scheduledMessages => 'Scheduled messages';

  @override
  String get search => 'Search';

  @override
  String get searchArchived => 'Search archived...';

  @override
  String get searchBlocked => 'Search blocked...';

  @override
  String get searchEmoji => 'Search emoji';

  @override
  String get searchInChat => 'Search in chat...';

  @override
  String get searchWeb => 'Search web';

  @override
  String get secondaryPinIsActive => 'Secondary PIN is active';

  @override
  String get securityTeam => 'Security Team';

  @override
  String get select => 'Select';

  @override
  String get selectAll => 'Select all';

  @override
  String get selectAtLeastOneMember => 'Select at least one member';

  @override
  String get selectBackup => 'Select Backup';

  @override
  String get selectBackupFile => 'Select Backup File';

  @override
  String get selectedFolderDoesNotExist => 'Selected folder does not exist';

  @override
  String get sendPhoto => 'Send photo';

  @override
  String get sendViewOnce => 'Send view once';

  @override
  String senderNameNewMessage(String senderName) {
    return '$senderName: New message';
  }

  @override
  String get sentPreview => 'Sent preview';

  @override
  String sentTo(String name) {
    return 'Sent to $name';
  }

  @override
  String get setAPanicPin =>
      'Set a panic PIN to quickly wipe or show a decoy profile.';

  @override
  String get setPanicPin => 'Set panic PIN';

  @override
  String get setPanicPinToEnablePanicMode =>
      'Set a panic PIN to enable panic mode';

  @override
  String get setSecondaryPanicPin => 'Set a secondary panic PIN';

  @override
  String get setUpPrysm => 'Set up Prysm';

  @override
  String get settings => 'Settings';

  @override
  String get settingsResetToDefaults => 'Settings reset to defaults';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get setupPasscode => 'Setup Passcode';

  @override
  String get severalPeopleAreTyping => 'Several people are typing…';

  @override
  String get shadowStrength => 'Shadow strength';

  @override
  String get shareThisIdOrQrSoOthersCan =>
      'Share this ID or QR so others can message you. You can always ';

  @override
  String get shareThisQrCodeWithOthersSoThey =>
      'Share this QR code with others so they can add you as a contact.';

  @override
  String get shareToPrysm => 'Share to Prysm';

  @override
  String get sharedMedia => 'Shared Media';

  @override
  String get showAnEmptyAppWhileYourRealData =>
      'Show an empty app while your real data stays encrypted on disk';

  @override
  String get showFullQr => 'Show full QR';

  @override
  String get showInChat => 'Show in chat';

  @override
  String get showMyQrCode => 'Show my QR code';

  @override
  String get showNotificationsForNewMessages =>
      'Show notifications for new messages';

  @override
  String get showOnlineStatus => 'Show Online Status';

  @override
  String get showPrysm => 'Show Prysm';

  @override
  String get showQr => 'Show QR';

  @override
  String get silenceMessageAlerts => 'Silence message alerts';

  @override
  String get skipForNow => 'Skip for now';

  @override
  String get skipPinOrPassphraseUsingBiometrics =>
      'Skip PIN or passphrase using fingerprint or face';

  @override
  String get skipTour => 'Skip tour';

  @override
  String get skipVersionCheckDesktopDryRun =>
      'Skip version check (desktop dry-run)';

  @override
  String get slidePreviewIsNotSupportedForThisFormat =>
      'Slide preview is not supported for this format in Prysm.';

  @override
  String get sourceCode => 'Source Code';

  @override
  String get spreadsheet => 'Spreadsheet';

  @override
  String get startMinimized => 'Start minimized';

  @override
  String get startMinimizedSubtitle => 'Launch Prysm hidden in the system tray';

  @override
  String get stopMessagesCallsAndProfileUpdates =>
      'Stop messages, calls, and profile updates';

  @override
  String get storageManager => 'Storage Manager';

  @override
  String get storageManagerUnavailable => 'Storage manager unavailable';

  @override
  String get storageUsage => 'Storage Usage';

  @override
  String get str1day => '1 day';

  @override
  String get str1hour => '1 hour';

  @override
  String get str1week => '1 week';

  @override
  String get str2hours => '2 hours';

  @override
  String get str30seconds => '30 seconds';

  @override
  String get str4hours => '4 hours';

  @override
  String get str4weeks => '4 weeks';

  @override
  String get str5minutes => '5 minutes';

  @override
  String get str6digitpin => '6-digit PIN';

  @override
  String get str8hours => '8 hours';

  @override
  String get switchingMethodsRequiresSettingANewUnlockCode =>
      'Switching methods requires setting a new unlock code.';

  @override
  String get systemDefault => 'System default';

  @override
  String get tapToAllowMessagesAndCallsAgain =>
      'Tap to allow messages and calls again';

  @override
  String get tapToChangeGroupPhoto => 'Tap to change group photo';

  @override
  String get tapToCopy => 'Tap to copy';

  @override
  String get tapToRename => 'Tap to rename';

  @override
  String get tapToRetry => 'Tap to retry';

  @override
  String get tapToSetGroupPhoto => 'Tap to set group photo';

  @override
  String get tapToView => 'Tap to View';

  @override
  String get testUpdateFlow => 'Test update flow';

  @override
  String get testersTeam => 'Testers Team';

  @override
  String get textSize => 'Text size';

  @override
  String get theLogFileMayContainSensitiveInformationOnly =>
      'The log file may contain sensitive information. Only share it with trusted parties.';

  @override
  String get theScannedQrCodeDoesNotMatchThis =>
      'The scanned QR code does not match this contact\'s identity. ';

  @override
  String get theirQrCode => 'Their QR code';

  @override
  String get thisContactWillBeAbleToMessageAnd =>
      'This contact will be able to message and call you again.';

  @override
  String get thisContactWillNoLongerBeMarkedAs =>
      'This contact will no longer be marked as verified.';

  @override
  String get thisIsYourSecondaryPinForEmergencyUse =>
      'This is your secondary PIN for emergency use.';

  @override
  String get thisIsYourUniqueAddressOnTorFriends =>
      'This is your unique address on Tor. Friends use it to add you. ';

  @override
  String get thisQrCodeIsNotAValidPrysm =>
      'This QR code is not a valid Prysm identity code.';

  @override
  String get thisRequestWillBeRemoved => 'This request will be removed.';

  @override
  String get thisWillPermanentlyDeleteAllCallLogs =>
      'This will permanently delete all call logs.';

  @override
  String get thisWillReplaceAllCurrentDataWithThe =>
      'This will replace all current data with the backup. The app will restart after restore.';

  @override
  String get thisWillRestoreAllSettingsToTheirDefault =>
      'This will restore all settings to their default values. This action cannot be undone.';

  @override
  String todayAtTime(String time) {
    return 'Today at $time';
  }

  @override
  String get tomorrow => 'Tomorrow';

  @override
  String tomorrowAtTime(String time) {
    return 'Tomorrow at $time';
  }

  @override
  String torBootstrapPercent(String percent) {
    return 'Tor: $percent%';
  }

  @override
  String get torConnection => 'Tor connection';

  @override
  String get torIsConnected => 'Tor is connected';

  @override
  String get torIsConnecting => 'Tor is connecting…';

  @override
  String get torNeedsAttentionAutomaticRecoveryPaused =>
      'Tor needs attention — automatic recovery paused. ';

  @override
  String get torNetworkRouting => '• Tor network routing';

  @override
  String torRestartFailedE(String e) {
    return 'Tor restart failed: $e';
  }

  @override
  String get torRestartedSuccessfully => 'Tor restarted successfully';

  @override
  String get torStatusConnected => 'Connected';

  @override
  String get torStatusConnecting => 'Connecting';

  @override
  String torStatusConnectingPercent(String percent) {
    return 'Connecting ($percent)';
  }

  @override
  String get torStatusOff => 'Off';

  @override
  String get total => 'Total';

  @override
  String trayPendingMessage(int count) {
    return 'Pending: $count message';
  }

  @override
  String trayPendingMessages(int count) {
    return 'Pending: $count messages';
  }

  @override
  String trayPendingShort(int count) {
    return '$count pending';
  }

  @override
  String trayTooltipBase(String status) {
    return 'Prysm · Tor $status';
  }

  @override
  String trayUnreadCount(int count) {
    return 'Unread: $count';
  }

  @override
  String trayUnreadShort(int count) {
    return '$count unread';
  }

  @override
  String get turnNotificationsBackOn => 'Turn notifications back on';

  @override
  String twoPeopleAreTyping(String first, String second) {
    return '$first and $second are typing…';
  }

  @override
  String get typingIndicators => 'Typing Indicators';

  @override
  String get uiUxTeam => 'UI/UX Team';

  @override
  String get unableToDecryptMessage => 'Unable to decrypt message';

  @override
  String get unarchiveChat => 'Unarchive chat';

  @override
  String get unblock => 'Unblock';

  @override
  String get unblockContact => 'Unblock contact';

  @override
  String get unblockContactBody => 'They will be able to message you again.';

  @override
  String get unblockContactQuestion => 'Unblock contact?';

  @override
  String get unblockToSendMessages => 'Unblock to send messages';

  @override
  String get unknown => 'Unknown';

  @override
  String get unlock => 'Unlock';

  @override
  String get unlockMethod => 'Unlock method';

  @override
  String get unlockMethodConfigured => 'Unlock method configured';

  @override
  String get unlockMethodSaved => 'Unlock method saved';

  @override
  String get unlockMethodSetTo6DigitPin => 'Unlock method set to 6-digit PIN';

  @override
  String get unlockMethodSetToPassphrase => 'Unlock method set to passphrase';

  @override
  String get unlockPrysm => 'Unlock Prysm';

  @override
  String get unlockWithBiometrics => 'Unlock with biometrics';

  @override
  String get unlockWithBiometricsSubtitle =>
      'Use fingerprint or face to unlock';

  @override
  String get unlocking => 'Unlocking…';

  @override
  String get unpinChat => 'Unpin chat';

  @override
  String get untilITurnItBackOn => 'Until I turn it back on';

  @override
  String get untilYouTurnThemBackOn => 'until you turn them back on';

  @override
  String get upTo5Members => 'Up to 5 members';

  @override
  String updateAvailable(String tagName) {
    return 'Update available ($tagName)';
  }

  @override
  String updateAvailableTagname(String tagName) {
    return 'Update available ($tagName)';
  }

  @override
  String get updateNow => 'Update now';

  @override
  String get updateUnlockPassphraseSubtitle =>
      'Update your unlock passphrase without changing your identity';

  @override
  String get updateUnlockPinSubtitle =>
      'Update your unlock PIN without changing your identity';

  @override
  String get updatesAreNotAvailableOnIos => 'Updates are not available on iOS.';

  @override
  String get updatingPrysm => 'Updating Prysm';

  @override
  String get uploadFile => 'Upload File';

  @override
  String get uploadImage => 'Upload Image';

  @override
  String get useFingerprintOrFace => 'Use your fingerprint or face';

  @override
  String get usePasscode => 'Use passcode';

  @override
  String get useSystemDefault => 'Use system default';

  @override
  String get userId => 'User ID';

  @override
  String get userIdBase58OnionUrl => 'User ID (Base58 Onion URL)';

  @override
  String get userInterfaceDesign => 'User Interface Design';

  @override
  String get verificationFailed => 'Verification failed';

  @override
  String get verificationRemoved => 'Verification removed';

  @override
  String get verified => 'Verified';

  @override
  String versionLabel(String version) {
    return 'Version $version';
  }

  @override
  String get video => 'Video';

  @override
  String get videoNotReady => 'Video not ready';

  @override
  String get viewOnGithub => 'View on GitHub';

  @override
  String get viewOnce => 'View Once';

  @override
  String get viewOnce2 => 'View once';

  @override
  String get viewOnce3 => 'View once';

  @override
  String get viewOncePhoto => 'View Once Photo';

  @override
  String get viewProfile => 'View profile';

  @override
  String get voiceMessage => 'Voice message';

  @override
  String get voiceMessageCacheExpired => 'Voice message cache expired';

  @override
  String get voiceMessageQueuedWillSendWhenPeerIs =>
      'Voice message queued. Will send when peer is available.';

  @override
  String get voicePreview => '🎤 Voice';

  @override
  String get waitingForGroupKey => 'Waiting for group key…';

  @override
  String get welcomeBack => 'Welcome back';

  @override
  String welcomeBackDisplayname(String displayName) {
    return 'Welcome back, $displayName';
  }

  @override
  String get welcomeToPrysm => 'Welcome to Prysm';

  @override
  String get whenDisabledYouWontSendOrSeeTypingActivity =>
      'When disabled, you won\'t send or see typing activity in chats.';

  @override
  String get whenEnabledPeopleWhoAreNotInYour =>
      'When enabled, people who are not in your contacts cannot message or call you directly.';

  @override
  String get whenEnabledRecentContactsAreNotifiedWhenYou =>
      'When enabled, recent contacts are notified when you come online so they can deliver pending messages faster.';

  @override
  String get whenPanicPinIsUsed => 'When panic PIN is used';

  @override
  String whoSetMessagesToDisappearIn(String who) {
    return '$who set messages to disappear in ';
  }

  @override
  String whoTurnedOffDisappearingMessages(String who) {
    return '$who turned off disappearing messages';
  }

  @override
  String willSendAt(String label) {
    return 'Will send $label';
  }

  @override
  String get wipeLocalDataAndContinue => 'Wipe local data and continue';

  @override
  String get wipeLocalKeys => 'Wipe local keys';

  @override
  String get yes => 'Yes';

  @override
  String get you => 'You';

  @override
  String get youAreAdmin => 'You are admin';

  @override
  String get youAreNoLongerInThisGroup => 'You are no longer in this group';

  @override
  String get youWillNoLongerReceiveMessagesCallsOr =>
      'You will no longer receive messages, calls, or profile updates from this contact.';

  @override
  String get yourId => 'Your ID';

  @override
  String get yourPassphraseProtectsYourKeys =>
      'Your passphrase protects your keys';

  @override
  String get yourPinProtectsYourKeys => 'Your PIN protects your keys';

  @override
  String get yourPrysmId => 'Your Prysm ID';

  @override
  String get yourPrysmIdWillAppearOnceTorFinishes =>
      'Your Prysm ID will appear once Tor finishes connecting.';

  @override
  String get chatMediaFilterAll => 'All';

  @override
  String get chatMediaFilterFiles => 'Files';

  @override
  String get chatMediaFilterPhotos => 'Photos';

  @override
  String get chatMediaFilterVoice => 'Voice';

  @override
  String get chooseATimeInTheFuture => 'Choose a time in the future';

  @override
  String deleteMediaFromConversation(String label, String conversation) {
    return 'Delete \"$label\" from $conversation? This removes it from your device only.';
  }

  @override
  String groupInviteReceivedAt(String receivedAt) {
    return 'Group invite · $receivedAt';
  }

  @override
  String scheduleSendsAt(String label) {
    return 'Sends $label';
  }

  @override
  String get sendHoldToSchedule => 'Send. Hold to schedule';

  @override
  String get today => 'Today';

  @override
  String get youWillNeedThisPasswordToRestore =>
      'You will need this password to restore.';

  @override
  String get openWithSystemApp => 'Open with system app';

  @override
  String get displayNameHintExample => 'eg. Alice';

  @override
  String get showQrCode => 'Show QR Code';
}
