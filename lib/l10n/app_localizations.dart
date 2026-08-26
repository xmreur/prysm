import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_it.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('it'),
  ];

  /// No description provided for @aNewVersionIsAvailable.
  ///
  /// In en, this message translates to:
  /// **'A new version is available.'**
  String get aNewVersionIsAvailable;

  /// No description provided for @aPanicPinIsASecondPasscodeEntering.
  ///
  /// In en, this message translates to:
  /// **'A panic PIN is a second passcode. Entering it at unlock '**
  String get aPanicPinIsASecondPasscodeEntering;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutApp.
  ///
  /// In en, this message translates to:
  /// **'About {appName}'**
  String aboutApp(String appName);

  /// No description provided for @aboutThisApp.
  ///
  /// In en, this message translates to:
  /// **'About This App'**
  String get aboutThisApp;

  /// No description provided for @accept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get accept;

  /// No description provided for @acceptCall.
  ///
  /// In en, this message translates to:
  /// **'Accept call'**
  String get acceptCall;

  /// No description provided for @activeCallsChannel.
  ///
  /// In en, this message translates to:
  /// **'Active Calls'**
  String get activeCallsChannel;

  /// No description provided for @activeCallsChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Ongoing voice calls'**
  String get activeCallsChannelDescription;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @addContact.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get addContact;

  /// No description provided for @addContactAndJoin.
  ///
  /// In en, this message translates to:
  /// **'Add contact and join'**
  String get addContactAndJoin;

  /// No description provided for @addContactOfflineHint.
  ///
  /// In en, this message translates to:
  /// **'Connect to Tor to add contacts. You can skip this step and add friends later from the main app.'**
  String get addContactOfflineHint;

  /// No description provided for @addContactOnlineHint.
  ///
  /// In en, this message translates to:
  /// **'Ask a friend for their Prysm ID (a Base58 code or QR). They must be online on Tor for the first connection.'**
  String get addContactOnlineHint;

  /// No description provided for @addContactsBeforeCreatingAGroup.
  ///
  /// In en, this message translates to:
  /// **'Add contacts before creating a group'**
  String get addContactsBeforeCreatingAGroup;

  /// No description provided for @addMember.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get addMember;

  /// No description provided for @addYourFirstContact.
  ///
  /// In en, this message translates to:
  /// **'Add your first contact'**
  String get addYourFirstContact;

  /// No description provided for @addedMemberWillReceiveInviteWhenOnline.
  ///
  /// In en, this message translates to:
  /// **'Added {name}. They will receive an invite when online.'**
  String addedMemberWillReceiveInviteWhenOnline(String name);

  /// No description provided for @admin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get admin;

  /// No description provided for @advancedPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Advanced Privacy'**
  String get advancedPrivacy;

  /// No description provided for @after5FailedUnlockAttemptsLock2Hours.
  ///
  /// In en, this message translates to:
  /// **'After 5 failed unlock attempts, Prysm locks for 2 hours'**
  String get after5FailedUnlockAttemptsLock2Hours;

  /// No description provided for @alignTheQrCodeInsideTheFrameTo.
  ///
  /// In en, this message translates to:
  /// **'Align the QR code inside the frame to scan.'**
  String get alignTheQrCodeInsideTheFrameTo;

  /// No description provided for @anInviteFromSomeoneWhoIsNotIn.
  ///
  /// In en, this message translates to:
  /// **'An invite from someone who is not in your contacts is kept as a '**
  String get anInviteFromSomeoneWhoIsNotIn;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Prysm'**
  String get appTitle;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @archiveChat.
  ///
  /// In en, this message translates to:
  /// **'Archive chat'**
  String get archiveChat;

  /// No description provided for @archived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archived;

  /// No description provided for @areYouSureYouWantToDeleteAll.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete all messages in this chat? This cannot be undone.'**
  String get areYouSureYouWantToDeleteAll;

  /// No description provided for @areYouSureYouWantToDeleteThis.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this contact? This cannot be undone.'**
  String get areYouSureYouWantToDeleteThis;

  /// No description provided for @askYourContactToShowThisCodeOr.
  ///
  /// In en, this message translates to:
  /// **'Ask your contact to show this code, or scan theirs to verify.'**
  String get askYourContactToShowThisCodeOr;

  /// No description provided for @audioNotReady.
  ///
  /// In en, this message translates to:
  /// **'Audio not ready'**
  String get audioNotReady;

  /// No description provided for @autoRestarts.
  ///
  /// In en, this message translates to:
  /// **'Auto-restarts: '**
  String get autoRestarts;

  /// No description provided for @autoRestartsLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-restarts:'**
  String get autoRestartsLabel;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @backToChats.
  ///
  /// In en, this message translates to:
  /// **'Back to chats'**
  String get backToChats;

  /// No description provided for @backUpYourAccount.
  ///
  /// In en, this message translates to:
  /// **'Back up your account'**
  String get backUpYourAccount;

  /// No description provided for @backupCreateAnytimeInSettings.
  ///
  /// In en, this message translates to:
  /// **'You can create more backups anytime in Settings → Data'**
  String get backupCreateAnytimeInSettings;

  /// No description provided for @backupCreated.
  ///
  /// In en, this message translates to:
  /// **'Backup created'**
  String get backupCreated;

  /// No description provided for @backupEncryptedFileBullet.
  ///
  /// In en, this message translates to:
  /// **'Backups are password-encrypted files (.prysmbackup)'**
  String get backupEncryptedFileBullet;

  /// No description provided for @backupFailedE.
  ///
  /// In en, this message translates to:
  /// **'Backup failed: {e}'**
  String backupFailedE(String e);

  /// No description provided for @backupOnboardingBody.
  ///
  /// In en, this message translates to:
  /// **'A backup saves your chats, contacts, and encrypted keys. Without one, losing this device or forgetting your unlock code means losing everything.'**
  String get backupOnboardingBody;

  /// No description provided for @backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup Password'**
  String get backupPassword;

  /// No description provided for @backupRestoredPleaseRestartTheApp.
  ///
  /// In en, this message translates to:
  /// **'Backup restored! Please restart the app.'**
  String get backupRestoredPleaseRestartTheApp;

  /// No description provided for @backupSavedTo.
  ///
  /// In en, this message translates to:
  /// **'Backup saved to {path}'**
  String backupSavedTo(String path);

  /// No description provided for @backupStoreOutsideDevice.
  ///
  /// In en, this message translates to:
  /// **'Store the file somewhere safe outside this device'**
  String get backupStoreOutsideDevice;

  /// No description provided for @batterySaverAutoEnabledBatteryAt.
  ///
  /// In en, this message translates to:
  /// **'Auto-enabled — battery at {level}%'**
  String batterySaverAutoEnabledBatteryAt(int level);

  /// No description provided for @batterySaverAutoEnabledPowerSaverOn.
  ///
  /// In en, this message translates to:
  /// **'Auto-enabled — device power saver on'**
  String get batterySaverAutoEnabledPowerSaverOn;

  /// No description provided for @batterySaverAutoEnablesAt.
  ///
  /// In en, this message translates to:
  /// **'Auto-enables at {threshold}% battery or below'**
  String batterySaverAutoEnablesAt(int threshold);

  /// No description provided for @batterySaverReducesPolling.
  ///
  /// In en, this message translates to:
  /// **'Reduces polling and background activity'**
  String get batterySaverReducesPolling;

  /// No description provided for @batterySaving.
  ///
  /// In en, this message translates to:
  /// **'Battery saving'**
  String get batterySaving;

  /// No description provided for @biometricsNotSupportedOnThisPlatform.
  ///
  /// In en, this message translates to:
  /// **'Biometrics not supported on this platform'**
  String get biometricsNotSupportedOnThisPlatform;

  /// No description provided for @block.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get block;

  /// No description provided for @blockContact.
  ///
  /// In en, this message translates to:
  /// **'Block contact'**
  String get blockContact;

  /// No description provided for @blockContactBody.
  ///
  /// In en, this message translates to:
  /// **'They won\'t be able to message you.'**
  String get blockContactBody;

  /// No description provided for @blockContactQuestion.
  ///
  /// In en, this message translates to:
  /// **'Block contact?'**
  String get blockContactQuestion;

  /// No description provided for @blocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blocked;

  /// No description provided for @blockedContacts.
  ///
  /// In en, this message translates to:
  /// **'Blocked contacts'**
  String get blockedContacts;

  /// No description provided for @blockedViewProfile.
  ///
  /// In en, this message translates to:
  /// **'Blocked · View profile'**
  String get blockedViewProfile;

  /// No description provided for @bugFindingFeatureSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Bug finding & Feature suggestions'**
  String get bugFindingFeatureSuggestions;

  /// No description provided for @builtOnTor.
  ///
  /// In en, this message translates to:
  /// **'Built on Tor'**
  String get builtOnTor;

  /// No description provided for @caches.
  ///
  /// In en, this message translates to:
  /// **'Caches'**
  String get caches;

  /// No description provided for @cachesCleared.
  ///
  /// In en, this message translates to:
  /// **'Caches cleared'**
  String get cachesCleared;

  /// No description provided for @calculating.
  ///
  /// In en, this message translates to:
  /// **'Calculating…'**
  String get calculating;

  /// No description provided for @callBack.
  ///
  /// In en, this message translates to:
  /// **'Call back'**
  String get callBack;

  /// No description provided for @callDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get callDuration;

  /// No description provided for @callHistory.
  ///
  /// In en, this message translates to:
  /// **'Call History'**
  String get callHistory;

  /// No description provided for @callMicrophone.
  ///
  /// In en, this message translates to:
  /// **'Call microphone'**
  String get callMicrophone;

  /// No description provided for @callPreview.
  ///
  /// In en, this message translates to:
  /// **'📞 Call'**
  String get callPreview;

  /// No description provided for @callStarted.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get callStarted;

  /// No description provided for @cameraPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Camera Permission Required'**
  String get cameraPermissionRequired;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @cancelMessage.
  ///
  /// In en, this message translates to:
  /// **'Cancel message'**
  String get cancelMessage;

  /// No description provided for @cancelScheduledMessage.
  ///
  /// In en, this message translates to:
  /// **'Cancel scheduled message?'**
  String get cancelScheduledMessage;

  /// No description provided for @changePanicPin.
  ///
  /// In en, this message translates to:
  /// **'Change panic PIN'**
  String get changePanicPin;

  /// No description provided for @changePasscode.
  ///
  /// In en, this message translates to:
  /// **'Change passcode'**
  String get changePasscode;

  /// No description provided for @changeUnlockMethodInSettingsPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Change unlock method anytime in Settings → Privacy'**
  String get changeUnlockMethodInSettingsPrivacy;

  /// No description provided for @chatMedia.
  ///
  /// In en, this message translates to:
  /// **'Chat Media'**
  String get chatMedia;

  /// No description provided for @chatMedia2.
  ///
  /// In en, this message translates to:
  /// **'Chat media'**
  String get chatMedia2;

  /// No description provided for @chatMediaIsStoredEncryptedOnThisDevice.
  ///
  /// In en, this message translates to:
  /// **'Chat media is stored encrypted on this device. '**
  String get chatMediaIsStoredEncryptedOnThisDevice;

  /// No description provided for @chatMediaStoredEncryptedDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Chat media is stored encrypted on this device. Deleting media here removes it locally only — it may still exist for other participants.'**
  String get chatMediaStoredEncryptedDisclaimer;

  /// No description provided for @chatWithMyself.
  ///
  /// In en, this message translates to:
  /// **'Chat with myself'**
  String get chatWithMyself;

  /// No description provided for @chatWithMyself6.
  ///
  /// In en, this message translates to:
  /// **'chat with myself'**
  String get chatWithMyself6;

  /// No description provided for @chats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chats;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @checking.
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get checking;

  /// No description provided for @chooseANew6DigitPin.
  ///
  /// In en, this message translates to:
  /// **'Choose a new 6-digit PIN.'**
  String get chooseANew6DigitPin;

  /// No description provided for @chooseANewPassphraseAtLeast12Characters.
  ///
  /// In en, this message translates to:
  /// **'Choose a new passphrase (at least 12 characters).'**
  String get chooseANewPassphraseAtLeast12Characters;

  /// No description provided for @chooseAStrongPasswordToEncryptYourBackup.
  ///
  /// In en, this message translates to:
  /// **'Choose a strong password to encrypt your backup. '**
  String get chooseAStrongPasswordToEncryptYourBackup;

  /// No description provided for @chooseDownloadFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose download folder'**
  String get chooseDownloadFolder;

  /// No description provided for @chooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get chooseFolder;

  /// No description provided for @chooseYourUnlockMethod.
  ///
  /// In en, this message translates to:
  /// **'Choose your unlock method'**
  String get chooseYourUnlockMethod;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @clearCaches.
  ///
  /// In en, this message translates to:
  /// **'Clear caches'**
  String get clearCaches;

  /// No description provided for @clearCallHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear call history'**
  String get clearCallHistory;

  /// No description provided for @clearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get clearHistory;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @closeSearch.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get closeSearch;

  /// No description provided for @comingSoonNotWorking.
  ///
  /// In en, this message translates to:
  /// **'COMING SOON, NOT WORKING'**
  String get comingSoonNotWorking;

  /// No description provided for @completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completed;

  /// No description provided for @composerRounding.
  ///
  /// In en, this message translates to:
  /// **'Composer rounding'**
  String get composerRounding;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @confirmNewPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Confirm new panic PIN'**
  String get confirmNewPanicPin;

  /// No description provided for @confirmNewPin.
  ///
  /// In en, this message translates to:
  /// **'Confirm new PIN'**
  String get confirmNewPin;

  /// No description provided for @confirmPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Confirm panic PIN'**
  String get confirmPanicPin;

  /// No description provided for @confirmPasscode.
  ///
  /// In en, this message translates to:
  /// **'Confirm Passcode'**
  String get confirmPasscode;

  /// No description provided for @confirmPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Confirm Passphrase'**
  String get confirmPassphrase;

  /// No description provided for @confirmYourPin.
  ///
  /// In en, this message translates to:
  /// **'Confirm your PIN'**
  String get confirmYourPin;

  /// No description provided for @connectToTorBeforeAddingContacts.
  ///
  /// In en, this message translates to:
  /// **'Connect to Tor before adding contacts'**
  String get connectToTorBeforeAddingContacts;

  /// No description provided for @connectTor.
  ///
  /// In en, this message translates to:
  /// **'Connect Tor'**
  String get connectTor;

  /// No description provided for @connectTorForPrysmId.
  ///
  /// In en, this message translates to:
  /// **'Connect Tor for Prysm ID'**
  String get connectTorForPrysmId;

  /// No description provided for @connectViaOnionId.
  ///
  /// In en, this message translates to:
  /// **'Connect via onion ID'**
  String get connectViaOnionId;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// No description provided for @connecting2.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting2;

  /// No description provided for @connecting3.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting3;

  /// No description provided for @connecting4.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get connecting4;

  /// No description provided for @connectingBootstrap.
  ///
  /// In en, this message translates to:
  /// **'connecting ({bootstrap}%)'**
  String connectingBootstrap(String bootstrap);

  /// No description provided for @connectingToTor.
  ///
  /// In en, this message translates to:
  /// **'Connecting to Tor…'**
  String get connectingToTor;

  /// No description provided for @contactAdded.
  ///
  /// In en, this message translates to:
  /// **'Contact added'**
  String get contactAdded;

  /// No description provided for @contactAddedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Contact added successfully'**
  String get contactAddedSuccessfully;

  /// No description provided for @contactCountSummary.
  ///
  /// In en, this message translates to:
  /// **'{contactCount, plural, =1{1 contact} other{{contactCount} contacts}} · {groupCount, plural, =1{1 group} other{{groupCount} groups}}'**
  String contactCountSummary(int contactCount, int groupCount);

  /// No description provided for @contactInfo.
  ///
  /// In en, this message translates to:
  /// **'Contact Info'**
  String get contactInfo;

  /// No description provided for @contactNotFound.
  ///
  /// In en, this message translates to:
  /// **'Contact not found'**
  String get contactNotFound;

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @continueOffline.
  ///
  /// In en, this message translates to:
  /// **'Continue offline'**
  String get continueOffline;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copyId.
  ///
  /// In en, this message translates to:
  /// **'Copy ID'**
  String get copyId;

  /// No description provided for @couldNotAddContact.
  ///
  /// In en, this message translates to:
  /// **'Could not add contact'**
  String get couldNotAddContact;

  /// No description provided for @couldNotChangeUnlockMethod.
  ///
  /// In en, this message translates to:
  /// **'Could not change unlock method'**
  String get couldNotChangeUnlockMethod;

  /// No description provided for @couldNotConnectToPeerMessagesWillBe.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to peer. Messages will be queued.'**
  String get couldNotConnectToPeerMessagesWillBe;

  /// No description provided for @couldNotCopy.
  ///
  /// In en, this message translates to:
  /// **'Could not copy'**
  String get couldNotCopy;

  /// No description provided for @couldNotCreateGroupMakeSureAllMembers.
  ///
  /// In en, this message translates to:
  /// **'Could not create group. Make sure all members are online and try again.'**
  String get couldNotCreateGroupMakeSureAllMembers;

  /// No description provided for @couldNotDeleteFileE.
  ///
  /// In en, this message translates to:
  /// **'Could not delete file: {e}'**
  String couldNotDeleteFileE(String e);

  /// No description provided for @couldNotDeleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Could not delete for everyone'**
  String get couldNotDeleteForEveryone;

  /// No description provided for @couldNotDeleteMediaE.
  ///
  /// In en, this message translates to:
  /// **'Could not delete media: {e}'**
  String couldNotDeleteMediaE(String e);

  /// No description provided for @couldNotEditMessage.
  ///
  /// In en, this message translates to:
  /// **'Could not edit message'**
  String get couldNotEditMessage;

  /// No description provided for @couldNotLoadDownloadsE.
  ///
  /// In en, this message translates to:
  /// **'Could not load downloads: {e}'**
  String couldNotLoadDownloadsE(String e);

  /// No description provided for @couldNotLoadImage.
  ///
  /// In en, this message translates to:
  /// **'Could not load image'**
  String get couldNotLoadImage;

  /// No description provided for @couldNotLoadMediaE.
  ///
  /// In en, this message translates to:
  /// **'Could not load media: {e}'**
  String couldNotLoadMediaE(String e);

  /// No description provided for @couldNotLoadPreview.
  ///
  /// In en, this message translates to:
  /// **'Could not load preview'**
  String get couldNotLoadPreview;

  /// No description provided for @couldNotLoadStorageUsageE.
  ///
  /// In en, this message translates to:
  /// **'Could not load storage usage: {e}'**
  String couldNotLoadStorageUsageE(String e);

  /// No description provided for @couldNotOpenFileE.
  ///
  /// In en, this message translates to:
  /// **'Could not open file: {e}'**
  String couldNotOpenFileE(String e);

  /// No description provided for @couldNotOpenImageE.
  ///
  /// In en, this message translates to:
  /// **'Could not open image: {e}'**
  String couldNotOpenImageE(String e);

  /// No description provided for @couldNotOpenSeparateWindowE.
  ///
  /// In en, this message translates to:
  /// **'Could not open separate window: {e}'**
  String couldNotOpenSeparateWindowE(String e);

  /// No description provided for @couldNotOpenVideoE.
  ///
  /// In en, this message translates to:
  /// **'Could not open video: {e}'**
  String couldNotOpenVideoE(String e);

  /// No description provided for @couldNotPlayVoiceMessageE.
  ///
  /// In en, this message translates to:
  /// **'Could not play voice message: {e}'**
  String couldNotPlayVoiceMessageE(String e);

  /// No description provided for @couldNotReadDroppedFileE.
  ///
  /// In en, this message translates to:
  /// **'Could not read dropped file: {e}'**
  String couldNotReadDroppedFileE(String e);

  /// No description provided for @couldNotReadFileE.
  ///
  /// In en, this message translates to:
  /// **'Could not read file: {e}'**
  String couldNotReadFileE(String e);

  /// No description provided for @couldNotReadPresentationContentInPrysm.
  ///
  /// In en, this message translates to:
  /// **'Could not read presentation content in Prysm.'**
  String get couldNotReadPresentationContentInPrysm;

  /// No description provided for @couldNotReadSpreadsheet.
  ///
  /// In en, this message translates to:
  /// **'Could not read spreadsheet'**
  String get couldNotReadSpreadsheet;

  /// No description provided for @couldNotSaveImage.
  ///
  /// In en, this message translates to:
  /// **'Could not save image: {e}'**
  String couldNotSaveImage(String e);

  /// No description provided for @couldNotScheduleMessageE.
  ///
  /// In en, this message translates to:
  /// **'Could not schedule message: {e}'**
  String couldNotScheduleMessageE(String e);

  /// No description provided for @couldNotSendFileGroupKeyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not send file — group key unavailable'**
  String get couldNotSendFileGroupKeyUnavailable;

  /// No description provided for @couldNotSendMessageGroupKeyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not send message — group key unavailable'**
  String get couldNotSendMessageGroupKeyUnavailable;

  /// No description provided for @couldNotSetUpPasscodeTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Could not set up passcode. Try again.'**
  String get couldNotSetUpPasscodeTryAgain;

  /// No description provided for @couldNotSetUpPassphraseMin12.
  ///
  /// In en, this message translates to:
  /// **'Could not set up passphrase. Use at least 12 characters.'**
  String get couldNotSetUpPassphraseMin12;

  /// No description provided for @couldNotSetUpPinTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Could not set up PIN. Try again.'**
  String get couldNotSetUpPinTryAgain;

  /// No description provided for @couldNotStartCallE.
  ///
  /// In en, this message translates to:
  /// **'Could not start call: {e}'**
  String couldNotStartCallE(String e);

  /// No description provided for @couldNotUpdateUnlockCode.
  ///
  /// In en, this message translates to:
  /// **'Could not update unlock code'**
  String get couldNotUpdateUnlockCode;

  /// No description provided for @count.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String count(String count);

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @createAnotherBackup.
  ///
  /// In en, this message translates to:
  /// **'Create another backup'**
  String get createAnotherBackup;

  /// No description provided for @createBackup.
  ///
  /// In en, this message translates to:
  /// **'Create Backup'**
  String get createBackup;

  /// No description provided for @createBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Create backup now'**
  String get createBackupNow;

  /// No description provided for @createGroup.
  ///
  /// In en, this message translates to:
  /// **'Create Group'**
  String get createGroup;

  /// No description provided for @createGroup2.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get createGroup2;

  /// No description provided for @createPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Create Passphrase'**
  String get createPassphrase;

  /// No description provided for @createYourPin.
  ///
  /// In en, this message translates to:
  /// **'Create your PIN'**
  String get createYourPin;

  /// No description provided for @cryptoUpgradeRequired.
  ///
  /// In en, this message translates to:
  /// **'Crypto upgrade required'**
  String get cryptoUpgradeRequired;

  /// No description provided for @currentPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Current panic PIN'**
  String get currentPanicPin;

  /// No description provided for @currentPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Current passphrase'**
  String get currentPassphrase;

  /// No description provided for @currentPin.
  ///
  /// In en, this message translates to:
  /// **'Current PIN'**
  String get currentPin;

  /// No description provided for @cut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get cut;

  /// No description provided for @cyanMode.
  ///
  /// In en, this message translates to:
  /// **'Cyan Mode'**
  String get cyanMode;

  /// No description provided for @dMoYHMin.
  ///
  /// In en, this message translates to:
  /// **'{d}/{mo}/{y} - {h}:{min}'**
  String dMoYHMin(String d, String mo, String y, String h, String min);

  /// No description provided for @dangerZone.
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get dangerZone;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// No description provided for @data.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get data;

  /// No description provided for @debugOptions.
  ///
  /// In en, this message translates to:
  /// **'Debug options'**
  String get debugOptions;

  /// No description provided for @decline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get decline;

  /// No description provided for @declineCall.
  ///
  /// In en, this message translates to:
  /// **'Decline call'**
  String get declineCall;

  /// No description provided for @declined.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get declined;

  /// No description provided for @decoyProfile.
  ///
  /// In en, this message translates to:
  /// **'Decoy profile'**
  String get decoyProfile;

  /// No description provided for @defaultInput.
  ///
  /// In en, this message translates to:
  /// **'Default input'**
  String get defaultInput;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteAllMessagesInThisChat.
  ///
  /// In en, this message translates to:
  /// **'Delete all messages in this chat'**
  String get deleteAllMessagesInThisChat;

  /// No description provided for @deleteChat.
  ///
  /// In en, this message translates to:
  /// **'Delete Chat'**
  String get deleteChat;

  /// No description provided for @deleteContact.
  ///
  /// In en, this message translates to:
  /// **'Delete Contact'**
  String get deleteContact;

  /// No description provided for @deleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete file'**
  String get deleteFile;

  /// No description provided for @deleteFileFromDownloads.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{fileName}\" from downloads?'**
  String deleteFileFromDownloads(String fileName);

  /// No description provided for @deleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get deleteForEveryone;

  /// No description provided for @deleteGroup.
  ///
  /// In en, this message translates to:
  /// **'Delete group'**
  String get deleteGroup;

  /// No description provided for @deleteMedia.
  ///
  /// In en, this message translates to:
  /// **'Delete media'**
  String get deleteMedia;

  /// No description provided for @deleteTemporaryImageAndVoiceCaches.
  ///
  /// In en, this message translates to:
  /// **'Delete temporary image and voice caches? '**
  String get deleteTemporaryImageAndVoiceCaches;

  /// No description provided for @deleteThisContactFromYourListCannotBe.
  ///
  /// In en, this message translates to:
  /// **'Delete this contact from your list. Cannot be undone.'**
  String get deleteThisContactFromYourListCannotBe;

  /// No description provided for @deleteThisGroupForEveryoneThisCannotBe.
  ///
  /// In en, this message translates to:
  /// **'Delete this group for everyone? This cannot be undone.'**
  String get deleteThisGroupForEveryoneThisCannotBe;

  /// No description provided for @deleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get deleted;

  /// No description provided for @delivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get delivered;

  /// No description provided for @delivery.
  ///
  /// In en, this message translates to:
  /// **'Delivery'**
  String get delivery;

  /// No description provided for @destroyKeysAndLocalDatabasesThenShowAn.
  ///
  /// In en, this message translates to:
  /// **'Destroy keys and local databases, then show an empty app'**
  String get destroyKeysAndLocalDatabasesThenShowAn;

  /// No description provided for @directionCallDuration.
  ///
  /// In en, this message translates to:
  /// **'{direction} call · {duration}'**
  String directionCallDuration(String direction, String duration);

  /// No description provided for @directionCallStatus.
  ///
  /// In en, this message translates to:
  /// **'{direction} call · {status}'**
  String directionCallStatus(String direction, String status);

  /// No description provided for @disappearing1d.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get disappearing1d;

  /// No description provided for @disappearing1h.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get disappearing1h;

  /// No description provided for @disappearing1w.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get disappearing1w;

  /// No description provided for @disappearing30s.
  ///
  /// In en, this message translates to:
  /// **'30 seconds'**
  String get disappearing30s;

  /// No description provided for @disappearing4w.
  ///
  /// In en, this message translates to:
  /// **'4 weeks'**
  String get disappearing4w;

  /// No description provided for @disappearing5m.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get disappearing5m;

  /// No description provided for @disappearing8h.
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get disappearing8h;

  /// No description provided for @disappearingDurationDays.
  ///
  /// In en, this message translates to:
  /// **'{count}d'**
  String disappearingDurationDays(int count);

  /// No description provided for @disappearingDurationHours.
  ///
  /// In en, this message translates to:
  /// **'{count}h'**
  String disappearingDurationHours(int count);

  /// No description provided for @disappearingDurationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count}m'**
  String disappearingDurationMinutes(int count);

  /// No description provided for @disappearingDurationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{count}s'**
  String disappearingDurationSeconds(int count);

  /// No description provided for @disappearingDurationWeeks.
  ///
  /// In en, this message translates to:
  /// **'{count}w'**
  String disappearingDurationWeeks(int count);

  /// No description provided for @disappearingMessages.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages'**
  String get disappearingMessages;

  /// No description provided for @disappearingOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get disappearingOff;

  /// No description provided for @disappearsAfterViewing.
  ///
  /// In en, this message translates to:
  /// **'🔒 Disappears after viewing'**
  String get disappearsAfterViewing;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @discardInvite.
  ///
  /// In en, this message translates to:
  /// **'Discard invite'**
  String get discardInvite;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @diskUsageAndMediaManagement.
  ///
  /// In en, this message translates to:
  /// **'Disk usage and media management'**
  String get diskUsageAndMediaManagement;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @displayName.
  ///
  /// In en, this message translates to:
  /// **'Display Name'**
  String get displayName;

  /// No description provided for @displayName2.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayName2;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @downloadAnyway.
  ///
  /// In en, this message translates to:
  /// **'Download anyway'**
  String get downloadAnyway;

  /// No description provided for @downloadFailedE.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {e}'**
  String downloadFailedE(String e);

  /// No description provided for @downloadFromGithubReleases.
  ///
  /// In en, this message translates to:
  /// **'Download from GitHub releases'**
  String get downloadFromGithubReleases;

  /// No description provided for @downloadLocation.
  ///
  /// In en, this message translates to:
  /// **'Download Location'**
  String get downloadLocation;

  /// No description provided for @downloadLocationResetToDefault.
  ///
  /// In en, this message translates to:
  /// **'Download location reset to default'**
  String get downloadLocationResetToDefault;

  /// No description provided for @downloadRiskyFile.
  ///
  /// In en, this message translates to:
  /// **'Download risky file?'**
  String get downloadRiskyFile;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloading;

  /// No description provided for @downloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloads;

  /// No description provided for @downloadsFolderNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Downloads folder not available'**
  String get downloadsFolderNotAvailable;

  /// No description provided for @downloadsWillBeSavedToPath.
  ///
  /// In en, this message translates to:
  /// **'Downloads will be saved to {path}'**
  String downloadsWillBeSavedToPath(String path);

  /// No description provided for @dropToSend.
  ///
  /// In en, this message translates to:
  /// **'Drop to send'**
  String get dropToSend;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @editMessage.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get editMessage;

  /// No description provided for @editName.
  ///
  /// In en, this message translates to:
  /// **'Edit Name'**
  String get editName;

  /// No description provided for @emergency.
  ///
  /// In en, this message translates to:
  /// **'Emergency'**
  String get emergency;

  /// No description provided for @emptyFile.
  ///
  /// In en, this message translates to:
  /// **'Empty file'**
  String get emptyFile;

  /// No description provided for @enableRelayServer.
  ///
  /// In en, this message translates to:
  /// **'Enable Relay Server'**
  String get enableRelayServer;

  /// No description provided for @encryptionPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Encryption & Privacy'**
  String get encryptionPrivacy;

  /// No description provided for @endToEndEncryption.
  ///
  /// In en, this message translates to:
  /// **'• End-to-end encryption'**
  String get endToEndEncryption;

  /// No description provided for @enterAGroupName.
  ///
  /// In en, this message translates to:
  /// **'Enter a group name'**
  String get enterAGroupName;

  /// No description provided for @enterAValidBase58PrysmId.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid Base58 Prysm ID'**
  String get enterAValidBase58PrysmId;

  /// No description provided for @enterBothIdAndDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Enter both ID and display name'**
  String get enterBothIdAndDisplayName;

  /// No description provided for @enterPanicPinToRemove.
  ///
  /// In en, this message translates to:
  /// **'Enter panic PIN to remove'**
  String get enterPanicPinToRemove;

  /// No description provided for @enterPasscode.
  ///
  /// In en, this message translates to:
  /// **'Enter Passcode'**
  String get enterPasscode;

  /// No description provided for @enterPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Enter Passphrase'**
  String get enterPassphrase;

  /// No description provided for @enterPassphraseOrPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Enter passphrase or panic PIN'**
  String get enterPassphraseOrPanicPin;

  /// No description provided for @enterYourCurrentUnlockPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Enter your current unlock passphrase.'**
  String get enterYourCurrentUnlockPassphrase;

  /// No description provided for @enterYourCurrentUnlockPin.
  ///
  /// In en, this message translates to:
  /// **'Enter your current unlock PIN.'**
  String get enterYourCurrentUnlockPin;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @exportEncryptedBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Export encrypted backup file'**
  String get exportEncryptedBackupFile;

  /// No description provided for @exportLog.
  ///
  /// In en, this message translates to:
  /// **'Export Log'**
  String get exportLog;

  /// No description provided for @failed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get failed;

  /// No description provided for @failedToCreateGroupE.
  ///
  /// In en, this message translates to:
  /// **'Failed to create group: {e}'**
  String failedToCreateGroupE(String e);

  /// No description provided for @failedToExportLog.
  ///
  /// In en, this message translates to:
  /// **'Failed to export log: {e}'**
  String failedToExportLog(String e);

  /// No description provided for @failedToExportLogE.
  ///
  /// In en, this message translates to:
  /// **'Failed to export log: {e}'**
  String failedToExportLogE(String e);

  /// No description provided for @failedToPlayVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Failed to play voice message'**
  String get failedToPlayVoiceMessage;

  /// No description provided for @failedToRefreshCircuit.
  ///
  /// In en, this message translates to:
  /// **'Failed to refresh circuit'**
  String get failedToRefreshCircuit;

  /// No description provided for @features.
  ///
  /// In en, this message translates to:
  /// **'Features:'**
  String get features;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @fileDeleted.
  ///
  /// In en, this message translates to:
  /// **'File deleted'**
  String get fileDeleted;

  /// No description provided for @fileIsStillDecryptingOrEmpty.
  ///
  /// In en, this message translates to:
  /// **'File is still decrypting or empty'**
  String get fileIsStillDecryptingOrEmpty;

  /// No description provided for @fileMayBeHarmfulOnlyDownloadIfTrusted.
  ///
  /// In en, this message translates to:
  /// **'{fileName} may be harmful to your device. Only download if you trust the sender.'**
  String fileMayBeHarmfulOnlyDownloadIfTrusted(String fileName);

  /// No description provided for @fileNotReadyToDownload.
  ///
  /// In en, this message translates to:
  /// **'File not ready to download'**
  String get fileNotReadyToDownload;

  /// No description provided for @filePreview.
  ///
  /// In en, this message translates to:
  /// **'📎 File'**
  String get filePreview;

  /// No description provided for @filePreviews.
  ///
  /// In en, this message translates to:
  /// **'File previews'**
  String get filePreviews;

  /// No description provided for @filePreviewsInChatSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show inline previews for documents, images, and media in chat'**
  String get filePreviewsInChatSubtitle;

  /// No description provided for @filePreviewsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show inline previews for images and documents'**
  String get filePreviewsSubtitle;

  /// No description provided for @fileQueuedWillSendWhenPeerIsAvailable.
  ///
  /// In en, this message translates to:
  /// **'File queued. Will send when peer is available.'**
  String get fileQueuedWillSendWhenPeerIsAvailable;

  /// No description provided for @fileTooLargeToPreview.
  ///
  /// In en, this message translates to:
  /// **'File too large to preview'**
  String get fileTooLargeToPreview;

  /// No description provided for @filenameMayBeHarmfulToYourDevice.
  ///
  /// In en, this message translates to:
  /// **'{fileName} may be harmful to your device. '**
  String filenameMayBeHarmfulToYourDevice(String fileName);

  /// No description provided for @fingerprint.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get fingerprint;

  /// No description provided for @fingerprintCopied.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint copied'**
  String get fingerprintCopied;

  /// No description provided for @font.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get font;

  /// No description provided for @fontIbmPlexSans.
  ///
  /// In en, this message translates to:
  /// **'IBM Plex Sans'**
  String get fontIbmPlexSans;

  /// No description provided for @fontInter.
  ///
  /// In en, this message translates to:
  /// **'Inter'**
  String get fontInter;

  /// No description provided for @fontJetBrainsMono.
  ///
  /// In en, this message translates to:
  /// **'JetBrains Mono'**
  String get fontJetBrainsMono;

  /// No description provided for @fontSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get fontSystem;

  /// No description provided for @galleryAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Gallery access denied'**
  String get galleryAccessDenied;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get getStarted;

  /// No description provided for @gettingStarted.
  ///
  /// In en, this message translates to:
  /// **'Getting started'**
  String get gettingStarted;

  /// No description provided for @goOnlineToSendAndReceiveMessages.
  ///
  /// In en, this message translates to:
  /// **'Go online to send and receive messages'**
  String get goOnlineToSendAndReceiveMessages;

  /// No description provided for @group.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get group;

  /// No description provided for @groupChat.
  ///
  /// In en, this message translates to:
  /// **'Group chat'**
  String get groupChat;

  /// No description provided for @groupInviteContactsOnlyDescription.
  ///
  /// In en, this message translates to:
  /// **'Invites from anyone else are discarded the moment they arrive: nothing is stored, nothing is shown.'**
  String get groupInviteContactsOnlyDescription;

  /// No description provided for @groupInviteContactsOnlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Only accept invites from contacts'**
  String get groupInviteContactsOnlyTitle;

  /// No description provided for @groupInviteHoldDescription.
  ///
  /// In en, this message translates to:
  /// **'An invite from someone who is not in your contacts is kept as a request. Your device never contacts them, and adding them as a contact is what applies the invite.'**
  String get groupInviteHoldDescription;

  /// No description provided for @groupInviteHoldTitle.
  ///
  /// In en, this message translates to:
  /// **'Hold invites from unknown senders'**
  String get groupInviteHoldTitle;

  /// No description provided for @groupInvites.
  ///
  /// In en, this message translates to:
  /// **'Group invites'**
  String get groupInvites;

  /// No description provided for @groupIsFullMax.
  ///
  /// In en, this message translates to:
  /// **'Group is full ({max} members max)'**
  String groupIsFullMax(String max);

  /// No description provided for @groupIsFullMaxgroupmembersMembersMax.
  ///
  /// In en, this message translates to:
  /// **'Group is full ({maxGroupMembers} members max)'**
  String groupIsFullMaxgroupmembersMembersMax(String maxGroupMembers);

  /// No description provided for @groupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupName;

  /// No description provided for @groupPhotoUpdated.
  ///
  /// In en, this message translates to:
  /// **'Group photo updated'**
  String get groupPhotoUpdated;

  /// No description provided for @groupRenamed.
  ///
  /// In en, this message translates to:
  /// **'Group renamed'**
  String get groupRenamed;

  /// No description provided for @hangUp.
  ///
  /// In en, this message translates to:
  /// **'Hang up'**
  String get hangUp;

  /// No description provided for @healthCheck.
  ///
  /// In en, this message translates to:
  /// **'Health check: '**
  String get healthCheck;

  /// No description provided for @healthCheckLabel.
  ///
  /// In en, this message translates to:
  /// **'Health check:'**
  String get healthCheckLabel;

  /// No description provided for @helpSupport.
  ///
  /// In en, this message translates to:
  /// **'Help & Support'**
  String get helpSupport;

  /// No description provided for @hideEmojiPicker.
  ///
  /// In en, this message translates to:
  /// **'Hide emoji picker'**
  String get hideEmojiPicker;

  /// No description provided for @hideToTrayWhenClickingMinimize.
  ///
  /// In en, this message translates to:
  /// **'Hide to tray when clicking the minimize button'**
  String get hideToTrayWhenClickingMinimize;

  /// No description provided for @holdInvitesFromUnknownSenders.
  ///
  /// In en, this message translates to:
  /// **'Hold invites from unknown senders'**
  String get holdInvitesFromUnknownSenders;

  /// No description provided for @holdToRecordAVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message'**
  String get holdToRecordAVoiceMessage;

  /// No description provided for @hourMinutePeriod.
  ///
  /// In en, this message translates to:
  /// **'{hour}:{minute} {period}'**
  String hourMinutePeriod(String hour, String minute, String period);

  /// No description provided for @idCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'ID copied to clipboard'**
  String get idCopiedToClipboard;

  /// No description provided for @idNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'ID not available'**
  String get idNotAvailable;

  /// No description provided for @identityVerification.
  ///
  /// In en, this message translates to:
  /// **'Identity verification'**
  String get identityVerification;

  /// No description provided for @identityVerified.
  ///
  /// In en, this message translates to:
  /// **'Identity verified'**
  String get identityVerified;

  /// No description provided for @image.
  ///
  /// In en, this message translates to:
  /// **'📷 Image'**
  String get image;

  /// No description provided for @imageNotReadyToSave.
  ///
  /// In en, this message translates to:
  /// **'Image not ready to save'**
  String get imageNotReadyToSave;

  /// No description provided for @imageSavedFileName.
  ///
  /// In en, this message translates to:
  /// **'Image saved ({fileName})'**
  String imageSavedFileName(String fileName);

  /// No description provided for @importFromBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Import from backup file'**
  String get importFromBackupFile;

  /// No description provided for @inAppPdfPreviewIsNotAvailableOn.
  ///
  /// In en, this message translates to:
  /// **'In-app PDF preview is not available on this platform.'**
  String get inAppPdfPreviewIsNotAvailableOn;

  /// No description provided for @inCall.
  ///
  /// In en, this message translates to:
  /// **'In call'**
  String get inCall;

  /// No description provided for @incoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming'**
  String get incoming;

  /// No description provided for @incomingCall.
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get incomingCall;

  /// No description provided for @incomingCalls.
  ///
  /// In en, this message translates to:
  /// **'Incoming Calls'**
  String get incomingCalls;

  /// No description provided for @incomingCallsChannel.
  ///
  /// In en, this message translates to:
  /// **'Incoming Calls'**
  String get incomingCallsChannel;

  /// No description provided for @incomingCallsChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Ringing incoming voice calls'**
  String get incomingCallsChannelDescription;

  /// No description provided for @incorrectPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Incorrect panic PIN'**
  String get incorrectPanicPin;

  /// No description provided for @incorrectPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Incorrect passphrase'**
  String get incorrectPassphrase;

  /// No description provided for @incorrectPin.
  ///
  /// In en, this message translates to:
  /// **'Incorrect PIN'**
  String get incorrectPin;

  /// No description provided for @info.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get info;

  /// No description provided for @installPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Install permission required'**
  String get installPermissionRequired;

  /// No description provided for @invalidQrCode.
  ///
  /// In en, this message translates to:
  /// **'Invalid QR code'**
  String get invalidQrCode;

  /// No description provided for @inviteRequests.
  ///
  /// In en, this message translates to:
  /// **'Invite requests'**
  String get inviteRequests;

  /// No description provided for @invitesFromAnyoneElseAreDiscardedTheMoment.
  ///
  /// In en, this message translates to:
  /// **'Invites from anyone else are discarded the moment they arrive: '**
  String get invitesFromAnyoneElseAreDiscardedTheMoment;

  /// No description provided for @iosCameraUsage.
  ///
  /// In en, this message translates to:
  /// **'Prysm needs camera access to scan QR codes and add contacts.'**
  String get iosCameraUsage;

  /// No description provided for @iosMicrophoneUsage.
  ///
  /// In en, this message translates to:
  /// **'Prysm needs microphone access for voice messages and calls.'**
  String get iosMicrophoneUsage;

  /// No description provided for @iosPhotoLibraryAddUsage.
  ///
  /// In en, this message translates to:
  /// **'Prysm needs access to save images to your photo library.'**
  String get iosPhotoLibraryAddUsage;

  /// No description provided for @iosPhotoLibraryUsage.
  ///
  /// In en, this message translates to:
  /// **'Prysm needs access to your photo library when you share images into the app.'**
  String get iosPhotoLibraryUsage;

  /// No description provided for @itWillNotBeSent.
  ///
  /// In en, this message translates to:
  /// **'It will not be sent.'**
  String get itWillNotBeSent;

  /// No description provided for @keep.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get keep;

  /// No description provided for @keepPrysmRunningInTrayWhenClosing.
  ///
  /// In en, this message translates to:
  /// **'Keep Prysm running in the tray when closing the window'**
  String get keepPrysmRunningInTrayWhenClosing;

  /// No description provided for @keyChangedReVerify.
  ///
  /// In en, this message translates to:
  /// **'Key changed — re-verify'**
  String get keyChangedReVerify;

  /// No description provided for @labelModKey.
  ///
  /// In en, this message translates to:
  /// **'{label} ({mod}+{key})'**
  String labelModKey(String label, String mod, String key);

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageItalian.
  ///
  /// In en, this message translates to:
  /// **'Italiano'**
  String get languageItalian;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @lastIssue.
  ///
  /// In en, this message translates to:
  /// **'Last issue: '**
  String get lastIssue;

  /// No description provided for @lastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last Seen'**
  String get lastSeen;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @leadDeveloper.
  ///
  /// In en, this message translates to:
  /// **'Lead Developer'**
  String get leadDeveloper;

  /// No description provided for @leaveAction.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leaveAction;

  /// No description provided for @leaveGroup.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get leaveGroup;

  /// No description provided for @leaveThisGroup.
  ///
  /// In en, this message translates to:
  /// **'Leave this group?'**
  String get leaveThisGroup;

  /// No description provided for @legal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get legal;

  /// No description provided for @lightMode.
  ///
  /// In en, this message translates to:
  /// **'Light Mode'**
  String get lightMode;

  /// No description provided for @linkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get linkCopied;

  /// No description provided for @linkPreviews.
  ///
  /// In en, this message translates to:
  /// **'Link previews'**
  String get linkPreviews;

  /// No description provided for @linkPreviewsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fetch link metadata when you send URLs'**
  String get linkPreviewsSubtitle;

  /// No description provided for @linkPreviewsViaTorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fetch titles and images for URLs in messages via Tor'**
  String get linkPreviewsViaTorSubtitle;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @localDataError.
  ///
  /// In en, this message translates to:
  /// **'Local data error'**
  String get localDataError;

  /// No description provided for @logSavedTo.
  ///
  /// In en, this message translates to:
  /// **'Log saved to {path}'**
  String logSavedTo(String path);

  /// No description provided for @lookUp.
  ///
  /// In en, this message translates to:
  /// **'Look up'**
  String get lookUp;

  /// No description provided for @lookingUpContactOnTor.
  ///
  /// In en, this message translates to:
  /// **'Looking up contact on Tor...'**
  String get lookingUpContactOnTor;

  /// No description provided for @losePassphraseOnlyBackupRestores.
  ///
  /// In en, this message translates to:
  /// **'If you lose your passphrase, only a backup can restore your account'**
  String get losePassphraseOnlyBackupRestores;

  /// No description provided for @losePinOnlyBackupRestores.
  ///
  /// In en, this message translates to:
  /// **'If you lose your PIN, only a backup can restore your account'**
  String get losePinOnlyBackupRestores;

  /// No description provided for @markAsVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified'**
  String get markAsVerified;

  /// No description provided for @markVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark verified'**
  String get markVerified;

  /// No description provided for @maxMaxgroupmembersMembersTotal.
  ///
  /// In en, this message translates to:
  /// **'Max {maxGroupMembers} members total'**
  String maxMaxgroupmembersMembersTotal(String maxGroupMembers);

  /// No description provided for @mediaDeleted.
  ///
  /// In en, this message translates to:
  /// **'Media deleted'**
  String get mediaDeleted;

  /// No description provided for @member.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get member;

  /// No description provided for @memberDisplayNameWithYou.
  ///
  /// In en, this message translates to:
  /// **'{name} ({youLabel})'**
  String memberDisplayNameWithYou(String name, String youLabel);

  /// No description provided for @membersCount.
  ///
  /// In en, this message translates to:
  /// **'{count} / {max} members'**
  String membersCount(String count, String max);

  /// No description provided for @messageBubbleRounding.
  ///
  /// In en, this message translates to:
  /// **'Message bubble rounding'**
  String get messageBubbleRounding;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageHint;

  /// No description provided for @messageInfo.
  ///
  /// In en, this message translates to:
  /// **'Message info'**
  String get messageInfo;

  /// No description provided for @messageNotFoundInLoadedHistory.
  ///
  /// In en, this message translates to:
  /// **'Message not found in loaded history'**
  String get messageNotFoundInLoadedHistory;

  /// No description provided for @messageQueuedWillSendWhenMembersAreReachable.
  ///
  /// In en, this message translates to:
  /// **'Message queued. Will send when members are reachable.'**
  String get messageQueuedWillSendWhenMembersAreReachable;

  /// No description provided for @messageQueuedWillSendWhenPeerIsAvailable.
  ///
  /// In en, this message translates to:
  /// **'Message queued. Will send when peer is available.'**
  String get messageQueuedWillSendWhenPeerIsAvailable;

  /// No description provided for @messageShadows.
  ///
  /// In en, this message translates to:
  /// **'Message shadows'**
  String get messageShadows;

  /// No description provided for @messages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get messages;

  /// No description provided for @microphoneLevel.
  ///
  /// In en, this message translates to:
  /// **'Microphone level'**
  String get microphoneLevel;

  /// No description provided for @microphonePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied'**
  String get microphonePermissionDenied;

  /// No description provided for @minimizeToSystemTrayOnClose.
  ///
  /// In en, this message translates to:
  /// **'Minimize to system tray on close'**
  String get minimizeToSystemTrayOnClose;

  /// No description provided for @minimizeToTrayOnClose.
  ///
  /// In en, this message translates to:
  /// **'Minimize to tray on close'**
  String get minimizeToTrayOnClose;

  /// No description provided for @minimizeToTrayOnCloseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep Prysm running in the background when you close the window'**
  String get minimizeToTrayOnCloseSubtitle;

  /// No description provided for @minimizeToTrayWhenMinimizingWindow.
  ///
  /// In en, this message translates to:
  /// **'Minimize to tray when minimizing window'**
  String get minimizeToTrayWhenMinimizingWindow;

  /// No description provided for @minimum12Characters.
  ///
  /// In en, this message translates to:
  /// **'Minimum 12 characters'**
  String get minimum12Characters;

  /// No description provided for @minutesSeconds.
  ///
  /// In en, this message translates to:
  /// **'{minutes}:{seconds}'**
  String minutesSeconds(String minutes, String seconds);

  /// No description provided for @missed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get missed;

  /// No description provided for @mockUpdateUiNoDownload.
  ///
  /// In en, this message translates to:
  /// **'Mock update UI (no download)'**
  String get mockUpdateUiNoDownload;

  /// No description provided for @moreReactions.
  ///
  /// In en, this message translates to:
  /// **'More reactions…'**
  String get moreReactions;

  /// No description provided for @mustBeAtLeastNCharacters.
  ///
  /// In en, this message translates to:
  /// **'Must be at least {minLength} characters'**
  String mustBeAtLeastNCharacters(int minLength);

  /// No description provided for @muteNotifications.
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get muteNotifications;

  /// No description provided for @muted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get muted;

  /// No description provided for @mutedForDuration.
  ///
  /// In en, this message translates to:
  /// **'for {duration}'**
  String mutedForDuration(String duration);

  /// No description provided for @mutedUntilDateAndTime.
  ///
  /// In en, this message translates to:
  /// **'Muted until {date}, {time}'**
  String mutedUntilDateAndTime(String date, String time);

  /// No description provided for @mutedUntilTime.
  ///
  /// In en, this message translates to:
  /// **'Muted until {time}'**
  String mutedUntilTime(String time);

  /// No description provided for @mutedUntilYouTurnNotificationsBackOn.
  ///
  /// In en, this message translates to:
  /// **'Muted until you turn notifications back on'**
  String get mutedUntilYouTurnNotificationsBackOn;

  /// No description provided for @myQrCode.
  ///
  /// In en, this message translates to:
  /// **'My QR Code'**
  String get myQrCode;

  /// No description provided for @needsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get needsAttention;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get network;

  /// No description provided for @neverSharePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Never share your passphrase with anyone'**
  String get neverSharePassphrase;

  /// No description provided for @neverSharePin.
  ///
  /// In en, this message translates to:
  /// **'Never share your PIN with anyone'**
  String get neverSharePin;

  /// No description provided for @newCircuit.
  ///
  /// In en, this message translates to:
  /// **'New circuit'**
  String get newCircuit;

  /// No description provided for @newMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get newMessage;

  /// No description provided for @newMessagesChannel.
  ///
  /// In en, this message translates to:
  /// **'New Messages'**
  String get newMessagesChannel;

  /// No description provided for @newMessagesChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Notification channel for new messages'**
  String get newMessagesChannelDescription;

  /// No description provided for @newPanicPin.
  ///
  /// In en, this message translates to:
  /// **'New panic PIN'**
  String get newPanicPin;

  /// No description provided for @newPassphrase.
  ///
  /// In en, this message translates to:
  /// **'New passphrase'**
  String get newPassphrase;

  /// No description provided for @newPassphraseMustBeDifferent.
  ///
  /// In en, this message translates to:
  /// **'New passphrase must be different'**
  String get newPassphraseMustBeDifferent;

  /// No description provided for @newPin.
  ///
  /// In en, this message translates to:
  /// **'New PIN'**
  String get newPin;

  /// No description provided for @newPinMustBeDifferent.
  ///
  /// In en, this message translates to:
  /// **'New PIN must be different'**
  String get newPinMustBeDifferent;

  /// No description provided for @newTorCircuitRequested.
  ///
  /// In en, this message translates to:
  /// **'New Tor circuit requested'**
  String get newTorCircuitRequested;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @nextMatch.
  ///
  /// In en, this message translates to:
  /// **'Next match'**
  String get nextMatch;

  /// No description provided for @nextScheduleLabel.
  ///
  /// In en, this message translates to:
  /// **'Next: {label}'**
  String nextScheduleLabel(String label);

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @noBackupFilesFoundInLocation.
  ///
  /// In en, this message translates to:
  /// **'No backup files found in {location}'**
  String noBackupFilesFoundInLocation(String location);

  /// No description provided for @noBlockedContacts.
  ///
  /// In en, this message translates to:
  /// **'No blocked contacts'**
  String get noBlockedContacts;

  /// No description provided for @noCallsYet.
  ///
  /// In en, this message translates to:
  /// **'No calls yet'**
  String get noCallsYet;

  /// No description provided for @noCentralServers.
  ///
  /// In en, this message translates to:
  /// **'• No central servers'**
  String get noCentralServers;

  /// No description provided for @noContactsAvailableToAdd.
  ///
  /// In en, this message translates to:
  /// **'No contacts available to add'**
  String get noContactsAvailableToAdd;

  /// No description provided for @noConversationsFound.
  ///
  /// In en, this message translates to:
  /// **'No conversations found'**
  String get noConversationsFound;

  /// No description provided for @noDownloadedFiles.
  ///
  /// In en, this message translates to:
  /// **'No downloaded files'**
  String get noDownloadedFiles;

  /// No description provided for @noEmojiFound.
  ///
  /// In en, this message translates to:
  /// **'No emoji found'**
  String get noEmojiFound;

  /// No description provided for @noForgotPassphraseRecovery.
  ///
  /// In en, this message translates to:
  /// **'There is no \"forgot passphrase\" recovery'**
  String get noForgotPassphraseRecovery;

  /// No description provided for @noForgotPinRecovery.
  ///
  /// In en, this message translates to:
  /// **'There is no \"forgot PIN\" recovery'**
  String get noForgotPinRecovery;

  /// No description provided for @noIdentityKeyIsStoredForThisContact.
  ///
  /// In en, this message translates to:
  /// **'No identity key is stored for this contact yet.'**
  String get noIdentityKeyIsStoredForThisContact;

  /// No description provided for @noInviteRequests.
  ///
  /// In en, this message translates to:
  /// **'No invite requests'**
  String get noInviteRequests;

  /// No description provided for @noLogFileFound.
  ///
  /// In en, this message translates to:
  /// **'No log file found'**
  String get noLogFileFound;

  /// No description provided for @noMediaInThisConversationYet.
  ///
  /// In en, this message translates to:
  /// **'No media in this conversation yet'**
  String get noMediaInThisConversationYet;

  /// No description provided for @noMediaStored.
  ///
  /// In en, this message translates to:
  /// **'No media stored'**
  String get noMediaStored;

  /// No description provided for @noPreviewAvailable.
  ///
  /// In en, this message translates to:
  /// **'No preview available'**
  String get noPreviewAvailable;

  /// No description provided for @noReadInformationAvailable.
  ///
  /// In en, this message translates to:
  /// **'No read information available.'**
  String get noReadInformationAvailable;

  /// No description provided for @notVerified.
  ///
  /// In en, this message translates to:
  /// **'Not verified'**
  String get notVerified;

  /// No description provided for @notesToSelf.
  ///
  /// In en, this message translates to:
  /// **'Notes to self'**
  String get notesToSelf;

  /// No description provided for @notesToYourself.
  ///
  /// In en, this message translates to:
  /// **'Notes to yourself'**
  String get notesToYourself;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @notificationsEnabledForLabel.
  ///
  /// In en, this message translates to:
  /// **'Notifications enabled for {label}'**
  String notificationsEnabledForLabel(String label);

  /// No description provided for @notificationsMuted.
  ///
  /// In en, this message translates to:
  /// **'Notifications muted'**
  String get notificationsMuted;

  /// No description provided for @notificationsMutedMuteduntilForLabel.
  ///
  /// In en, this message translates to:
  /// **'Notifications muted {mutedUntil} for {label}'**
  String notificationsMutedMuteduntilForLabel(String mutedUntil, String label);

  /// No description provided for @notificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show alerts for new messages and calls'**
  String get notificationsSubtitle;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @offlineConnectLaterForPrysmId.
  ///
  /// In en, this message translates to:
  /// **'Offline — connect later to get your Prysm ID'**
  String get offlineConnectLaterForPrysmId;

  /// No description provided for @offlinePrysmOrRetry.
  ///
  /// In en, this message translates to:
  /// **'You can use Prysm offline or retry when you have a connection.'**
  String get offlinePrysmOrRetry;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @onboardingIdBody.
  ///
  /// In en, this message translates to:
  /// **'This is your unique address on Tor. Friends use it to add you. It is a Base58 encoding of your .onion hidden service address.'**
  String get onboardingIdBody;

  /// No description provided for @onboardingIdShareHint.
  ///
  /// In en, this message translates to:
  /// **'Share this ID or QR so others can message you. You can always find it in your profile or the sidebar.'**
  String get onboardingIdShareHint;

  /// No description provided for @onboardingStepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of {total}'**
  String onboardingStepOf(String current, String total);

  /// No description provided for @onboardingTorBody.
  ///
  /// In en, this message translates to:
  /// **'Prysm routes all traffic through the Tor network. Your messages reach contacts directly — no central server stores your chats.'**
  String get onboardingTorBody;

  /// No description provided for @onboardingTorBulletMustConnect.
  ///
  /// In en, this message translates to:
  /// **'Tor must be connected before you can message anyone'**
  String get onboardingTorBulletMustConnect;

  /// No description provided for @onboardingTorBulletOnionAddress.
  ///
  /// In en, this message translates to:
  /// **'Your onion address is your identity on the network'**
  String get onboardingTorBulletOnionAddress;

  /// No description provided for @onboardingTorBulletStatusBar.
  ///
  /// In en, this message translates to:
  /// **'The Tor status in the app bar shows your connection'**
  String get onboardingTorBulletStatusBar;

  /// No description provided for @onboardingWelcomeSetupRequired.
  ///
  /// In en, this message translates to:
  /// **'Choose how you unlock Prysm and protect your keys. This setup is required before you can use the app.'**
  String get onboardingWelcomeSetupRequired;

  /// No description provided for @onboardingWelcomeTour.
  ///
  /// In en, this message translates to:
  /// **'Private messaging over Tor. This short tour covers the essentials so you can start chatting confidently.'**
  String get onboardingWelcomeTour;

  /// No description provided for @onionAddress.
  ///
  /// In en, this message translates to:
  /// **'Onion: {address}'**
  String onionAddress(String address);

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @onlyAcceptInvitesFromContacts.
  ///
  /// In en, this message translates to:
  /// **'Only accept invites from contacts'**
  String get onlyAcceptInvitesFromContacts;

  /// No description provided for @onlyDownloadIfYouTrustTheSender.
  ///
  /// In en, this message translates to:
  /// **'Only download if you trust the sender.'**
  String get onlyDownloadIfYouTrustTheSender;

  /// No description provided for @onlyMarkContactVerifiedIfComparedFull.
  ///
  /// In en, this message translates to:
  /// **'Only mark this contact as verified if you compared their fingerprint in person or over a trusted channel.'**
  String get onlyMarkContactVerifiedIfComparedFull;

  /// No description provided for @onlyMarkThisContactAsVerifiedIfYou.
  ///
  /// In en, this message translates to:
  /// **'Only mark this contact as verified if you compared their '**
  String get onlyMarkThisContactAsVerifiedIfYou;

  /// No description provided for @onlyOneFileAtATime.
  ///
  /// In en, this message translates to:
  /// **'Only one file at a time'**
  String get onlyOneFileAtATime;

  /// No description provided for @openInASeparateWindow.
  ///
  /// In en, this message translates to:
  /// **'Open in a separate window'**
  String get openInASeparateWindow;

  /// No description provided for @openMenu.
  ///
  /// In en, this message translates to:
  /// **'Open menu'**
  String get openMenu;

  /// No description provided for @openNotification.
  ///
  /// In en, this message translates to:
  /// **'Open notification'**
  String get openNotification;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @openSettingsToAllowInstalls.
  ///
  /// In en, this message translates to:
  /// **'Open Settings to allow Prysm to install updates.'**
  String get openSettingsToAllowInstalls;

  /// No description provided for @openSource.
  ///
  /// In en, this message translates to:
  /// **'• Open source'**
  String get openSource;

  /// No description provided for @openToViewTheMessage.
  ///
  /// In en, this message translates to:
  /// **'Open to view the message'**
  String get openToViewTheMessage;

  /// No description provided for @openWithSystemPlayer.
  ///
  /// In en, this message translates to:
  /// **'Open with system player'**
  String get openWithSystemPlayer;

  /// No description provided for @opened.
  ///
  /// In en, this message translates to:
  /// **'Opened'**
  String get opened;

  /// No description provided for @opening.
  ///
  /// In en, this message translates to:
  /// **'Opening…'**
  String get opening;

  /// No description provided for @orangeMode.
  ///
  /// In en, this message translates to:
  /// **'Orange Mode'**
  String get orangeMode;

  /// No description provided for @originalMessageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Original message unavailable'**
  String get originalMessageUnavailable;

  /// No description provided for @otherAppData.
  ///
  /// In en, this message translates to:
  /// **'Other app data'**
  String get otherAppData;

  /// No description provided for @outboundQueueDepth.
  ///
  /// In en, this message translates to:
  /// **'Outbound queue depth: '**
  String get outboundQueueDepth;

  /// No description provided for @outboundQueueDepthLabel.
  ///
  /// In en, this message translates to:
  /// **'Outbound queue depth:'**
  String get outboundQueueDepthLabel;

  /// No description provided for @outgoing.
  ///
  /// In en, this message translates to:
  /// **'Outgoing'**
  String get outgoing;

  /// No description provided for @panicDecoyDescription.
  ///
  /// In en, this message translates to:
  /// **'Show an empty app while your real data stays encrypted on disk'**
  String get panicDecoyDescription;

  /// No description provided for @panicDecoyTitle.
  ///
  /// In en, this message translates to:
  /// **'Decoy profile'**
  String get panicDecoyTitle;

  /// No description provided for @panicMode.
  ///
  /// In en, this message translates to:
  /// **'Panic mode'**
  String get panicMode;

  /// No description provided for @panicPinCannotMatchYourMainPasscode.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN cannot match your main passcode'**
  String get panicPinCannotMatchYourMainPasscode;

  /// No description provided for @panicPinConfigured.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN configured'**
  String get panicPinConfigured;

  /// No description provided for @panicPinExplanationBody.
  ///
  /// In en, this message translates to:
  /// **'A panic PIN is a second passcode. Entering it at unlock never reveals your real chats. Configure what happens when it is used.'**
  String get panicPinExplanationBody;

  /// No description provided for @panicPinIsSet.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN is set'**
  String get panicPinIsSet;

  /// No description provided for @panicPinNotSet.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN not set'**
  String get panicPinNotSet;

  /// No description provided for @panicPinRemoved.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN removed'**
  String get panicPinRemoved;

  /// No description provided for @panicPinSaved.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN saved'**
  String get panicPinSaved;

  /// No description provided for @panicPinUpdated.
  ///
  /// In en, this message translates to:
  /// **'Panic PIN updated'**
  String get panicPinUpdated;

  /// No description provided for @panicWipeDescription.
  ///
  /// In en, this message translates to:
  /// **'Destroy keys and local databases, then show an empty app'**
  String get panicWipeDescription;

  /// No description provided for @panicWipeTitle.
  ///
  /// In en, this message translates to:
  /// **'Wipe local keys'**
  String get panicWipeTitle;

  /// No description provided for @passphrase.
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get passphrase;

  /// No description provided for @passphrase12Characters.
  ///
  /// In en, this message translates to:
  /// **'Passphrase (12+ characters)'**
  String get passphrase12Characters;

  /// No description provided for @passphraseCannotMatchYourPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Passphrase cannot match your panic PIN'**
  String get passphraseCannotMatchYourPanicPin;

  /// No description provided for @passphraseEncryptsKeysBody.
  ///
  /// In en, this message translates to:
  /// **'Your passphrase encrypts your private keys on this device — Prysm never sees or stores it in the cloud.'**
  String get passphraseEncryptsKeysBody;

  /// No description provided for @passphraseMustBeAtLeast12Characters.
  ///
  /// In en, this message translates to:
  /// **'Passphrase must be at least 12 characters'**
  String get passphraseMustBeAtLeast12Characters;

  /// No description provided for @passphraseUpdated.
  ///
  /// In en, this message translates to:
  /// **'Passphrase updated'**
  String get passphraseUpdated;

  /// No description provided for @passphrasesDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passphrases do not match'**
  String get passphrasesDoNotMatch;

  /// No description provided for @passwordMustBeAtLeast4Characters.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 4 characters'**
  String get passwordMustBeAtLeast4Characters;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @pdfDocument.
  ///
  /// In en, this message translates to:
  /// **'PDF document'**
  String get pdfDocument;

  /// No description provided for @peerIsMuted.
  ///
  /// In en, this message translates to:
  /// **'Peer is muted'**
  String get peerIsMuted;

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get pending;

  /// No description provided for @personIsTyping.
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String personIsTyping(String name);

  /// No description provided for @photo.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get photo;

  /// No description provided for @photoDisappearsAfterTheRecipientOpensIt.
  ///
  /// In en, this message translates to:
  /// **'Photo disappears after the recipient opens it'**
  String get photoDisappearsAfterTheRecipientOpensIt;

  /// No description provided for @photoPreview.
  ///
  /// In en, this message translates to:
  /// **'📷 Photo'**
  String get photoPreview;

  /// No description provided for @pickAConversationFromTheSidebarOrStart.
  ///
  /// In en, this message translates to:
  /// **'Pick a conversation from the sidebar or start a new one.'**
  String get pickAConversationFromTheSidebarOrStart;

  /// No description provided for @pickConversationFromSidebar.
  ///
  /// In en, this message translates to:
  /// **'Pick a conversation from the sidebar or start a new one.'**
  String get pickConversationFromSidebar;

  /// No description provided for @pickOneMethodYouCanChangeItLater.
  ///
  /// In en, this message translates to:
  /// **'Pick one method. You can change it later in Settings.'**
  String get pickOneMethodYouCanChangeItLater;

  /// No description provided for @pinCannotMatchYourPanicPin.
  ///
  /// In en, this message translates to:
  /// **'PIN cannot match your panic PIN'**
  String get pinCannotMatchYourPanicPin;

  /// No description provided for @pinChat.
  ///
  /// In en, this message translates to:
  /// **'Pin chat'**
  String get pinChat;

  /// No description provided for @pinEncryptsKeysBody.
  ///
  /// In en, this message translates to:
  /// **'Your 6-digit PIN encrypts your private keys on this device — Prysm never sees or stores it in the cloud.'**
  String get pinEncryptsKeysBody;

  /// No description provided for @pinMustBe6Digits.
  ///
  /// In en, this message translates to:
  /// **'PIN must be 6 digits'**
  String get pinMustBe6Digits;

  /// No description provided for @pinUpdated.
  ///
  /// In en, this message translates to:
  /// **'PIN updated'**
  String get pinUpdated;

  /// No description provided for @pinkMode.
  ///
  /// In en, this message translates to:
  /// **'Pink Mode'**
  String get pinkMode;

  /// No description provided for @pinsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'PINs don\'t match'**
  String get pinsDoNotMatch;

  /// No description provided for @presentation.
  ///
  /// In en, this message translates to:
  /// **'Presentation'**
  String get presentation;

  /// No description provided for @previewUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Preview unavailable'**
  String get previewUnavailable;

  /// No description provided for @previewUnavailableFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Preview unavailable (file too large)'**
  String get previewUnavailableFileTooLarge;

  /// No description provided for @previewUpdateDialog.
  ///
  /// In en, this message translates to:
  /// **'Preview update dialog'**
  String get previewUpdateDialog;

  /// No description provided for @previousMatch.
  ///
  /// In en, this message translates to:
  /// **'Previous match'**
  String get previousMatch;

  /// No description provided for @privacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacy;

  /// No description provided for @privacyInformation.
  ///
  /// In en, this message translates to:
  /// **'Privacy Information'**
  String get privacyInformation;

  /// No description provided for @privacySettings.
  ///
  /// In en, this message translates to:
  /// **'Privacy Settings'**
  String get privacySettings;

  /// No description provided for @privacySettingsBody.
  ///
  /// In en, this message translates to:
  /// **'These settings help you control your privacy on {appName}. Your choices will be applied across all your conversations.'**
  String privacySettingsBody(String appName);

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @profilePhoto.
  ///
  /// In en, this message translates to:
  /// **'Profile Photo'**
  String get profilePhoto;

  /// No description provided for @prysm03UsesNewEndToEnd.
  ///
  /// In en, this message translates to:
  /// **'Prysm 0.3 uses new end-to-end encryption (Curve25519 + AEAD). '**
  String get prysm03UsesNewEndToEnd;

  /// No description provided for @prysmCouldNotOpenItsLocalDatabaseThis.
  ///
  /// In en, this message translates to:
  /// **'Prysm could not open its local database. This can happen after '**
  String get prysmCouldNotOpenItsLocalDatabaseThis;

  /// No description provided for @prysmIdBase58Label.
  ///
  /// In en, this message translates to:
  /// **'Prysm ID (Base58)'**
  String get prysmIdBase58Label;

  /// No description provided for @prysmIdCopied.
  ///
  /// In en, this message translates to:
  /// **'Prysm ID copied'**
  String get prysmIdCopied;

  /// No description provided for @prysmIdCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Prysm ID copied to clipboard'**
  String get prysmIdCopiedToClipboard;

  /// No description provided for @prysmIdHintExample.
  ///
  /// In en, this message translates to:
  /// **'eg. 51EsbujFRDJLHJ'**
  String get prysmIdHintExample;

  /// No description provided for @prysmNeedsCameraAccessToScanQrCodes.
  ///
  /// In en, this message translates to:
  /// **'Prysm needs camera access to scan QR codes for adding contacts.'**
  String get prysmNeedsCameraAccessToScanQrCodes;

  /// No description provided for @purpleMode.
  ///
  /// In en, this message translates to:
  /// **'Purple Mode'**
  String get purpleMode;

  /// No description provided for @qrScanCompareFingerprintManually.
  ///
  /// In en, this message translates to:
  /// **'QR scanning is only supported on mobile devices. Compare the fingerprint manually and use \"Mark as verified\".'**
  String get qrScanCompareFingerprintManually;

  /// No description provided for @qrScanner.
  ///
  /// In en, this message translates to:
  /// **'QR Scanner'**
  String get qrScanner;

  /// No description provided for @qrScannerIsOnlySupportedOnMobileDevices.
  ///
  /// In en, this message translates to:
  /// **'QR Scanner is only supported on mobile devices (Android/iOS).'**
  String get qrScannerIsOnlySupportedOnMobileDevices;

  /// No description provided for @qrScanningIsOnlySupportedOnMobileDevices.
  ///
  /// In en, this message translates to:
  /// **'QR scanning is only supported on mobile devices. '**
  String get qrScanningIsOnlySupportedOnMobileDevices;

  /// No description provided for @quit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get quit;

  /// No description provided for @read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// No description provided for @readBy.
  ///
  /// In en, this message translates to:
  /// **'Read by'**
  String get readBy;

  /// No description provided for @readReceipts.
  ///
  /// In en, this message translates to:
  /// **'Read Receipts'**
  String get readReceipts;

  /// No description provided for @receivedPreview.
  ///
  /// In en, this message translates to:
  /// **'Received preview'**
  String get receivedPreview;

  /// No description provided for @recentTorLog.
  ///
  /// In en, this message translates to:
  /// **'Recent Tor log'**
  String get recentTorLog;

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording...'**
  String get recording;

  /// No description provided for @refreshTorCircuit.
  ///
  /// In en, this message translates to:
  /// **'Refresh Tor Circuit'**
  String get refreshTorCircuit;

  /// No description provided for @refuseMessagesFromNonContacts.
  ///
  /// In en, this message translates to:
  /// **'Refuse messages from non-contacts'**
  String get refuseMessagesFromNonContacts;

  /// No description provided for @refuseNonContactsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When enabled, people who are not in your contacts cannot message you directly.'**
  String get refuseNonContactsSubtitle;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @removeMember.
  ///
  /// In en, this message translates to:
  /// **'Remove member'**
  String get removeMember;

  /// No description provided for @removeMemberFromGroupQuestion.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from the group?'**
  String removeMemberFromGroupQuestion(String name);

  /// No description provided for @removePanicPin.
  ///
  /// In en, this message translates to:
  /// **'Remove panic PIN'**
  String get removePanicPin;

  /// No description provided for @removeVerification.
  ///
  /// In en, this message translates to:
  /// **'Remove verification'**
  String get removeVerification;

  /// No description provided for @renameGroup.
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get renameGroup;

  /// No description provided for @replayTheSetupTour.
  ///
  /// In en, this message translates to:
  /// **'Replay the setup tour'**
  String get replayTheSetupTour;

  /// No description provided for @reply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get reply;

  /// No description provided for @requestANewCircuitWhenConnectionsAreStuck.
  ///
  /// In en, this message translates to:
  /// **'Request a new circuit when connections are stuck'**
  String get requestANewCircuitWhenConnectionsAreStuck;

  /// No description provided for @requestCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 request} other{{count} requests}}'**
  String requestCount(int count);

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @resetAllSettings.
  ///
  /// In en, this message translates to:
  /// **'Reset All Settings?'**
  String get resetAllSettings;

  /// No description provided for @resetLocalDataAndContinue.
  ///
  /// In en, this message translates to:
  /// **'Reset local data and continue'**
  String get resetLocalDataAndContinue;

  /// No description provided for @resetSettings.
  ///
  /// In en, this message translates to:
  /// **'Reset Settings'**
  String get resetSettings;

  /// No description provided for @restartTor.
  ///
  /// In en, this message translates to:
  /// **'Restart Tor'**
  String get restartTor;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @restoreBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore Backup'**
  String get restoreBackup;

  /// No description provided for @restoreDefaultSettings.
  ///
  /// In en, this message translates to:
  /// **'Restore default settings'**
  String get restoreDefaultSettings;

  /// No description provided for @restoreFailedE.
  ///
  /// In en, this message translates to:
  /// **'Restore failed: {e}'**
  String restoreFailedE(String e);

  /// No description provided for @restoreFailedWrongPasswordOrCorruptFile.
  ///
  /// In en, this message translates to:
  /// **'Restore failed — wrong password or corrupt file'**
  String get restoreFailedWrongPasswordOrCorruptFile;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @retryCall.
  ///
  /// In en, this message translates to:
  /// **'Retry call'**
  String get retryCall;

  /// No description provided for @ringing.
  ///
  /// In en, this message translates to:
  /// **'Ringing...'**
  String get ringing;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @saveDebugLogToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Save debug log to download folder'**
  String get saveDebugLogToDownloads;

  /// No description provided for @saveImage.
  ///
  /// In en, this message translates to:
  /// **'Save image'**
  String get saveImage;

  /// No description provided for @savePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Save passphrase'**
  String get savePassphrase;

  /// No description provided for @savedFileName.
  ///
  /// In en, this message translates to:
  /// **'Saved {fileName}'**
  String savedFileName(String fileName);

  /// No description provided for @savedToGallery.
  ///
  /// In en, this message translates to:
  /// **'Saved to gallery'**
  String get savedToGallery;

  /// No description provided for @savedToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Saved to Photos'**
  String get savedToPhotos;

  /// No description provided for @scanContactQr.
  ///
  /// In en, this message translates to:
  /// **'Scan Contact QR'**
  String get scanContactQr;

  /// No description provided for @scanNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Scan not available'**
  String get scanNotAvailable;

  /// No description provided for @scanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get scanQr;

  /// No description provided for @scanQrCode.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get scanQrCode;

  /// No description provided for @scanText.
  ///
  /// In en, this message translates to:
  /// **'Scan text'**
  String get scanText;

  /// No description provided for @scannedQrDoesNotMatchContact.
  ///
  /// In en, this message translates to:
  /// **'The scanned QR code does not match this contact\'s identity. This may indicate impersonation.'**
  String get scannedQrDoesNotMatchContact;

  /// No description provided for @schedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get schedule;

  /// No description provided for @scheduleDateAt.
  ///
  /// In en, this message translates to:
  /// **'{date} at {time}'**
  String scheduleDateAt(String date, String time);

  /// No description provided for @scheduleMessage.
  ///
  /// In en, this message translates to:
  /// **'Schedule message'**
  String get scheduleMessage;

  /// No description provided for @scheduleTodayAt.
  ///
  /// In en, this message translates to:
  /// **'Today at {time}'**
  String scheduleTodayAt(String time);

  /// No description provided for @scheduleTomorrowAt.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow at {time}'**
  String scheduleTomorrowAt(String time);

  /// No description provided for @scheduleWeekdayAt.
  ///
  /// In en, this message translates to:
  /// **'{weekday} at {time}'**
  String scheduleWeekdayAt(String weekday, String time);

  /// No description provided for @scheduledMessageCancelled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled message cancelled'**
  String get scheduledMessageCancelled;

  /// No description provided for @scheduledMessages.
  ///
  /// In en, this message translates to:
  /// **'Scheduled messages'**
  String get scheduledMessages;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @searchArchived.
  ///
  /// In en, this message translates to:
  /// **'Search archived...'**
  String get searchArchived;

  /// No description provided for @searchBlocked.
  ///
  /// In en, this message translates to:
  /// **'Search blocked...'**
  String get searchBlocked;

  /// No description provided for @searchEmoji.
  ///
  /// In en, this message translates to:
  /// **'Search emoji'**
  String get searchEmoji;

  /// No description provided for @searchInChat.
  ///
  /// In en, this message translates to:
  /// **'Search in chat...'**
  String get searchInChat;

  /// No description provided for @searchWeb.
  ///
  /// In en, this message translates to:
  /// **'Search web'**
  String get searchWeb;

  /// No description provided for @secondaryPinIsActive.
  ///
  /// In en, this message translates to:
  /// **'Secondary PIN is active'**
  String get secondaryPinIsActive;

  /// No description provided for @securityTeam.
  ///
  /// In en, this message translates to:
  /// **'Security Team'**
  String get securityTeam;

  /// No description provided for @select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @selectAtLeastOneMember.
  ///
  /// In en, this message translates to:
  /// **'Select at least one member'**
  String get selectAtLeastOneMember;

  /// No description provided for @selectBackup.
  ///
  /// In en, this message translates to:
  /// **'Select Backup'**
  String get selectBackup;

  /// No description provided for @selectBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Select Backup File'**
  String get selectBackupFile;

  /// No description provided for @selectedFolderDoesNotExist.
  ///
  /// In en, this message translates to:
  /// **'Selected folder does not exist'**
  String get selectedFolderDoesNotExist;

  /// No description provided for @sendPhoto.
  ///
  /// In en, this message translates to:
  /// **'Send photo'**
  String get sendPhoto;

  /// No description provided for @sendViewOnce.
  ///
  /// In en, this message translates to:
  /// **'Send view once'**
  String get sendViewOnce;

  /// No description provided for @senderNameNewMessage.
  ///
  /// In en, this message translates to:
  /// **'{senderName}: New message'**
  String senderNameNewMessage(String senderName);

  /// No description provided for @sentPreview.
  ///
  /// In en, this message translates to:
  /// **'Sent preview'**
  String get sentPreview;

  /// No description provided for @sentTo.
  ///
  /// In en, this message translates to:
  /// **'Sent to {name}'**
  String sentTo(String name);

  /// No description provided for @setAPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Set a panic PIN to quickly wipe or show a decoy profile.'**
  String get setAPanicPin;

  /// No description provided for @setPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Set panic PIN'**
  String get setPanicPin;

  /// No description provided for @setPanicPinToEnablePanicMode.
  ///
  /// In en, this message translates to:
  /// **'Set a panic PIN to enable panic mode'**
  String get setPanicPinToEnablePanicMode;

  /// No description provided for @setSecondaryPanicPin.
  ///
  /// In en, this message translates to:
  /// **'Set a secondary panic PIN'**
  String get setSecondaryPanicPin;

  /// No description provided for @setUpPrysm.
  ///
  /// In en, this message translates to:
  /// **'Set up Prysm'**
  String get setUpPrysm;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @settingsResetToDefaults.
  ///
  /// In en, this message translates to:
  /// **'Settings reset to defaults'**
  String get settingsResetToDefaults;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @setupPasscode.
  ///
  /// In en, this message translates to:
  /// **'Setup Passcode'**
  String get setupPasscode;

  /// No description provided for @severalPeopleAreTyping.
  ///
  /// In en, this message translates to:
  /// **'Several people are typing…'**
  String get severalPeopleAreTyping;

  /// No description provided for @shadowStrength.
  ///
  /// In en, this message translates to:
  /// **'Shadow strength'**
  String get shadowStrength;

  /// No description provided for @shareThisIdOrQrSoOthersCan.
  ///
  /// In en, this message translates to:
  /// **'Share this ID or QR so others can message you. You can always '**
  String get shareThisIdOrQrSoOthersCan;

  /// No description provided for @shareThisQrCodeWithOthersSoThey.
  ///
  /// In en, this message translates to:
  /// **'Share this QR code with others so they can add you as a contact.'**
  String get shareThisQrCodeWithOthersSoThey;

  /// No description provided for @shareToPrysm.
  ///
  /// In en, this message translates to:
  /// **'Share to Prysm'**
  String get shareToPrysm;

  /// No description provided for @sharedMedia.
  ///
  /// In en, this message translates to:
  /// **'Shared Media'**
  String get sharedMedia;

  /// No description provided for @showAnEmptyAppWhileYourRealData.
  ///
  /// In en, this message translates to:
  /// **'Show an empty app while your real data stays encrypted on disk'**
  String get showAnEmptyAppWhileYourRealData;

  /// No description provided for @showFullQr.
  ///
  /// In en, this message translates to:
  /// **'Show full QR'**
  String get showFullQr;

  /// No description provided for @showInChat.
  ///
  /// In en, this message translates to:
  /// **'Show in chat'**
  String get showInChat;

  /// No description provided for @showMyQrCode.
  ///
  /// In en, this message translates to:
  /// **'Show my QR code'**
  String get showMyQrCode;

  /// No description provided for @showNotificationsForNewMessages.
  ///
  /// In en, this message translates to:
  /// **'Show notifications for new messages'**
  String get showNotificationsForNewMessages;

  /// No description provided for @showOnlineStatus.
  ///
  /// In en, this message translates to:
  /// **'Show Online Status'**
  String get showOnlineStatus;

  /// No description provided for @showPrysm.
  ///
  /// In en, this message translates to:
  /// **'Show Prysm'**
  String get showPrysm;

  /// No description provided for @showQr.
  ///
  /// In en, this message translates to:
  /// **'Show QR'**
  String get showQr;

  /// No description provided for @silenceMessageAlerts.
  ///
  /// In en, this message translates to:
  /// **'Silence message alerts'**
  String get silenceMessageAlerts;

  /// No description provided for @skipForNow.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get skipForNow;

  /// No description provided for @skipPinOrPassphraseUsingBiometrics.
  ///
  /// In en, this message translates to:
  /// **'Skip PIN or passphrase using fingerprint or face'**
  String get skipPinOrPassphraseUsingBiometrics;

  /// No description provided for @skipTour.
  ///
  /// In en, this message translates to:
  /// **'Skip tour'**
  String get skipTour;

  /// No description provided for @skipVersionCheckDesktopDryRun.
  ///
  /// In en, this message translates to:
  /// **'Skip version check (desktop dry-run)'**
  String get skipVersionCheckDesktopDryRun;

  /// No description provided for @slidePreviewIsNotSupportedForThisFormat.
  ///
  /// In en, this message translates to:
  /// **'Slide preview is not supported for this format in Prysm.'**
  String get slidePreviewIsNotSupportedForThisFormat;

  /// No description provided for @sourceCode.
  ///
  /// In en, this message translates to:
  /// **'Source Code'**
  String get sourceCode;

  /// No description provided for @spreadsheet.
  ///
  /// In en, this message translates to:
  /// **'Spreadsheet'**
  String get spreadsheet;

  /// No description provided for @startMinimized.
  ///
  /// In en, this message translates to:
  /// **'Start minimized'**
  String get startMinimized;

  /// No description provided for @startMinimizedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Launch Prysm hidden in the system tray'**
  String get startMinimizedSubtitle;

  /// No description provided for @stopMessagesCallsAndProfileUpdates.
  ///
  /// In en, this message translates to:
  /// **'Stop messages, calls, and profile updates'**
  String get stopMessagesCallsAndProfileUpdates;

  /// No description provided for @storageManager.
  ///
  /// In en, this message translates to:
  /// **'Storage Manager'**
  String get storageManager;

  /// No description provided for @storageManagerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Storage manager unavailable'**
  String get storageManagerUnavailable;

  /// No description provided for @storageUsage.
  ///
  /// In en, this message translates to:
  /// **'Storage Usage'**
  String get storageUsage;

  /// No description provided for @str1day.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get str1day;

  /// No description provided for @str1hour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get str1hour;

  /// No description provided for @str1week.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get str1week;

  /// No description provided for @str2hours.
  ///
  /// In en, this message translates to:
  /// **'2 hours'**
  String get str2hours;

  /// No description provided for @str30seconds.
  ///
  /// In en, this message translates to:
  /// **'30 seconds'**
  String get str30seconds;

  /// No description provided for @str4hours.
  ///
  /// In en, this message translates to:
  /// **'4 hours'**
  String get str4hours;

  /// No description provided for @str4weeks.
  ///
  /// In en, this message translates to:
  /// **'4 weeks'**
  String get str4weeks;

  /// No description provided for @str5minutes.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get str5minutes;

  /// No description provided for @str6digitpin.
  ///
  /// In en, this message translates to:
  /// **'6-digit PIN'**
  String get str6digitpin;

  /// No description provided for @str8hours.
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get str8hours;

  /// No description provided for @switchingMethodsRequiresSettingANewUnlockCode.
  ///
  /// In en, this message translates to:
  /// **'Switching methods requires setting a new unlock code.'**
  String get switchingMethodsRequiresSettingANewUnlockCode;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get systemDefault;

  /// No description provided for @tapToAllowMessagesAndCallsAgain.
  ///
  /// In en, this message translates to:
  /// **'Tap to allow messages and calls again'**
  String get tapToAllowMessagesAndCallsAgain;

  /// No description provided for @tapToChangeGroupPhoto.
  ///
  /// In en, this message translates to:
  /// **'Tap to change group photo'**
  String get tapToChangeGroupPhoto;

  /// No description provided for @tapToCopy.
  ///
  /// In en, this message translates to:
  /// **'Tap to copy'**
  String get tapToCopy;

  /// No description provided for @tapToRename.
  ///
  /// In en, this message translates to:
  /// **'Tap to rename'**
  String get tapToRename;

  /// No description provided for @tapToRetry.
  ///
  /// In en, this message translates to:
  /// **'Tap to retry'**
  String get tapToRetry;

  /// No description provided for @tapToSetGroupPhoto.
  ///
  /// In en, this message translates to:
  /// **'Tap to set group photo'**
  String get tapToSetGroupPhoto;

  /// No description provided for @tapToView.
  ///
  /// In en, this message translates to:
  /// **'Tap to View'**
  String get tapToView;

  /// No description provided for @testUpdateFlow.
  ///
  /// In en, this message translates to:
  /// **'Test update flow'**
  String get testUpdateFlow;

  /// No description provided for @testersTeam.
  ///
  /// In en, this message translates to:
  /// **'Testers Team'**
  String get testersTeam;

  /// No description provided for @textSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// No description provided for @theLogFileMayContainSensitiveInformationOnly.
  ///
  /// In en, this message translates to:
  /// **'The log file may contain sensitive information. Only share it with trusted parties.'**
  String get theLogFileMayContainSensitiveInformationOnly;

  /// No description provided for @theScannedQrCodeDoesNotMatchThis.
  ///
  /// In en, this message translates to:
  /// **'The scanned QR code does not match this contact\'s identity. '**
  String get theScannedQrCodeDoesNotMatchThis;

  /// No description provided for @theirQrCode.
  ///
  /// In en, this message translates to:
  /// **'Their QR code'**
  String get theirQrCode;

  /// No description provided for @thisContactWillBeAbleToMessageAnd.
  ///
  /// In en, this message translates to:
  /// **'This contact will be able to message and call you again.'**
  String get thisContactWillBeAbleToMessageAnd;

  /// No description provided for @thisContactWillNoLongerBeMarkedAs.
  ///
  /// In en, this message translates to:
  /// **'This contact will no longer be marked as verified.'**
  String get thisContactWillNoLongerBeMarkedAs;

  /// No description provided for @thisIsYourSecondaryPinForEmergencyUse.
  ///
  /// In en, this message translates to:
  /// **'This is your secondary PIN for emergency use.'**
  String get thisIsYourSecondaryPinForEmergencyUse;

  /// No description provided for @thisIsYourUniqueAddressOnTorFriends.
  ///
  /// In en, this message translates to:
  /// **'This is your unique address on Tor. Friends use it to add you. '**
  String get thisIsYourUniqueAddressOnTorFriends;

  /// No description provided for @thisQrCodeIsNotAValidPrysm.
  ///
  /// In en, this message translates to:
  /// **'This QR code is not a valid Prysm identity code.'**
  String get thisQrCodeIsNotAValidPrysm;

  /// No description provided for @thisRequestWillBeRemoved.
  ///
  /// In en, this message translates to:
  /// **'This request will be removed.'**
  String get thisRequestWillBeRemoved;

  /// No description provided for @thisWillPermanentlyDeleteAllCallLogs.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete all call logs.'**
  String get thisWillPermanentlyDeleteAllCallLogs;

  /// No description provided for @thisWillReplaceAllCurrentDataWithThe.
  ///
  /// In en, this message translates to:
  /// **'This will replace all current data with the backup. The app will restart after restore.'**
  String get thisWillReplaceAllCurrentDataWithThe;

  /// No description provided for @thisWillRestoreAllSettingsToTheirDefault.
  ///
  /// In en, this message translates to:
  /// **'This will restore all settings to their default values. This action cannot be undone.'**
  String get thisWillRestoreAllSettingsToTheirDefault;

  /// No description provided for @todayAtTime.
  ///
  /// In en, this message translates to:
  /// **'Today at {time}'**
  String todayAtTime(String time);

  /// No description provided for @tomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get tomorrow;

  /// No description provided for @tomorrowAtTime.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow at {time}'**
  String tomorrowAtTime(String time);

  /// No description provided for @torBootstrapPercent.
  ///
  /// In en, this message translates to:
  /// **'Tor: {percent}%'**
  String torBootstrapPercent(String percent);

  /// No description provided for @torConnection.
  ///
  /// In en, this message translates to:
  /// **'Tor connection'**
  String get torConnection;

  /// No description provided for @torIsConnected.
  ///
  /// In en, this message translates to:
  /// **'Tor is connected'**
  String get torIsConnected;

  /// No description provided for @torIsConnecting.
  ///
  /// In en, this message translates to:
  /// **'Tor is connecting…'**
  String get torIsConnecting;

  /// No description provided for @torNeedsAttentionAutomaticRecoveryPaused.
  ///
  /// In en, this message translates to:
  /// **'Tor needs attention — automatic recovery paused. '**
  String get torNeedsAttentionAutomaticRecoveryPaused;

  /// No description provided for @torNetworkRouting.
  ///
  /// In en, this message translates to:
  /// **'• Tor network routing'**
  String get torNetworkRouting;

  /// No description provided for @torRestartFailedE.
  ///
  /// In en, this message translates to:
  /// **'Tor restart failed: {e}'**
  String torRestartFailedE(String e);

  /// No description provided for @torRestartedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Tor restarted successfully'**
  String get torRestartedSuccessfully;

  /// No description provided for @torStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get torStatusConnected;

  /// No description provided for @torStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get torStatusConnecting;

  /// No description provided for @torStatusConnectingPercent.
  ///
  /// In en, this message translates to:
  /// **'Connecting ({percent})'**
  String torStatusConnectingPercent(String percent);

  /// No description provided for @torStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get torStatusOff;

  /// No description provided for @total.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get total;

  /// No description provided for @trayPendingMessage.
  ///
  /// In en, this message translates to:
  /// **'Pending: {count} message'**
  String trayPendingMessage(int count);

  /// No description provided for @trayPendingMessages.
  ///
  /// In en, this message translates to:
  /// **'Pending: {count} messages'**
  String trayPendingMessages(int count);

  /// No description provided for @trayPendingShort.
  ///
  /// In en, this message translates to:
  /// **'{count} pending'**
  String trayPendingShort(int count);

  /// No description provided for @trayTooltipBase.
  ///
  /// In en, this message translates to:
  /// **'Prysm · Tor {status}'**
  String trayTooltipBase(String status);

  /// No description provided for @trayUnreadCount.
  ///
  /// In en, this message translates to:
  /// **'Unread: {count}'**
  String trayUnreadCount(int count);

  /// No description provided for @trayUnreadShort.
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String trayUnreadShort(int count);

  /// No description provided for @turnNotificationsBackOn.
  ///
  /// In en, this message translates to:
  /// **'Turn notifications back on'**
  String get turnNotificationsBackOn;

  /// No description provided for @twoPeopleAreTyping.
  ///
  /// In en, this message translates to:
  /// **'{first} and {second} are typing…'**
  String twoPeopleAreTyping(String first, String second);

  /// No description provided for @typingIndicators.
  ///
  /// In en, this message translates to:
  /// **'Typing Indicators'**
  String get typingIndicators;

  /// No description provided for @uiUxTeam.
  ///
  /// In en, this message translates to:
  /// **'UI/UX Team'**
  String get uiUxTeam;

  /// No description provided for @unableToDecryptMessage.
  ///
  /// In en, this message translates to:
  /// **'Unable to decrypt message'**
  String get unableToDecryptMessage;

  /// No description provided for @unarchiveChat.
  ///
  /// In en, this message translates to:
  /// **'Unarchive chat'**
  String get unarchiveChat;

  /// No description provided for @unblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblock;

  /// No description provided for @unblockContact.
  ///
  /// In en, this message translates to:
  /// **'Unblock contact'**
  String get unblockContact;

  /// No description provided for @unblockContactBody.
  ///
  /// In en, this message translates to:
  /// **'They will be able to message you again.'**
  String get unblockContactBody;

  /// No description provided for @unblockContactQuestion.
  ///
  /// In en, this message translates to:
  /// **'Unblock contact?'**
  String get unblockContactQuestion;

  /// No description provided for @unblockToSendMessages.
  ///
  /// In en, this message translates to:
  /// **'Unblock to send messages'**
  String get unblockToSendMessages;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @unlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlock;

  /// No description provided for @unlockMethod.
  ///
  /// In en, this message translates to:
  /// **'Unlock method'**
  String get unlockMethod;

  /// No description provided for @unlockMethodConfigured.
  ///
  /// In en, this message translates to:
  /// **'Unlock method configured'**
  String get unlockMethodConfigured;

  /// No description provided for @unlockMethodSaved.
  ///
  /// In en, this message translates to:
  /// **'Unlock method saved'**
  String get unlockMethodSaved;

  /// No description provided for @unlockMethodSetTo6DigitPin.
  ///
  /// In en, this message translates to:
  /// **'Unlock method set to 6-digit PIN'**
  String get unlockMethodSetTo6DigitPin;

  /// No description provided for @unlockMethodSetToPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Unlock method set to passphrase'**
  String get unlockMethodSetToPassphrase;

  /// No description provided for @unlockPrysm.
  ///
  /// In en, this message translates to:
  /// **'Unlock Prysm'**
  String get unlockPrysm;

  /// No description provided for @unlockWithBiometrics.
  ///
  /// In en, this message translates to:
  /// **'Unlock with biometrics'**
  String get unlockWithBiometrics;

  /// No description provided for @unlockWithBiometricsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use fingerprint or face to unlock'**
  String get unlockWithBiometricsSubtitle;

  /// No description provided for @unlocking.
  ///
  /// In en, this message translates to:
  /// **'Unlocking…'**
  String get unlocking;

  /// No description provided for @unpinChat.
  ///
  /// In en, this message translates to:
  /// **'Unpin chat'**
  String get unpinChat;

  /// No description provided for @untilITurnItBackOn.
  ///
  /// In en, this message translates to:
  /// **'Until I turn it back on'**
  String get untilITurnItBackOn;

  /// No description provided for @untilYouTurnThemBackOn.
  ///
  /// In en, this message translates to:
  /// **'until you turn them back on'**
  String get untilYouTurnThemBackOn;

  /// No description provided for @upTo5Members.
  ///
  /// In en, this message translates to:
  /// **'Up to 5 members'**
  String get upTo5Members;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available ({tagName})'**
  String updateAvailable(String tagName);

  /// No description provided for @updateAvailableTagname.
  ///
  /// In en, this message translates to:
  /// **'Update available ({tagName})'**
  String updateAvailableTagname(String tagName);

  /// No description provided for @updateNow.
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get updateNow;

  /// No description provided for @updateUnlockPassphraseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Update your unlock passphrase without changing your identity'**
  String get updateUnlockPassphraseSubtitle;

  /// No description provided for @updateUnlockPinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Update your unlock PIN without changing your identity'**
  String get updateUnlockPinSubtitle;

  /// No description provided for @updatesAreNotAvailableOnIos.
  ///
  /// In en, this message translates to:
  /// **'Updates are not available on iOS.'**
  String get updatesAreNotAvailableOnIos;

  /// No description provided for @updatingPrysm.
  ///
  /// In en, this message translates to:
  /// **'Updating Prysm'**
  String get updatingPrysm;

  /// No description provided for @uploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get uploadFile;

  /// No description provided for @uploadImage.
  ///
  /// In en, this message translates to:
  /// **'Upload Image'**
  String get uploadImage;

  /// No description provided for @useFingerprintOrFace.
  ///
  /// In en, this message translates to:
  /// **'Use your fingerprint or face'**
  String get useFingerprintOrFace;

  /// No description provided for @usePasscode.
  ///
  /// In en, this message translates to:
  /// **'Use passcode'**
  String get usePasscode;

  /// No description provided for @useSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'Use system default'**
  String get useSystemDefault;

  /// No description provided for @userId.
  ///
  /// In en, this message translates to:
  /// **'User ID'**
  String get userId;

  /// No description provided for @userIdBase58OnionUrl.
  ///
  /// In en, this message translates to:
  /// **'User ID (Base58 Onion URL)'**
  String get userIdBase58OnionUrl;

  /// No description provided for @userInterfaceDesign.
  ///
  /// In en, this message translates to:
  /// **'User Interface Design'**
  String get userInterfaceDesign;

  /// No description provided for @verificationFailed.
  ///
  /// In en, this message translates to:
  /// **'Verification failed'**
  String get verificationFailed;

  /// No description provided for @verificationRemoved.
  ///
  /// In en, this message translates to:
  /// **'Verification removed'**
  String get verificationRemoved;

  /// No description provided for @verified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get verified;

  /// No description provided for @versionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String versionLabel(String version);

  /// No description provided for @video.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get video;

  /// No description provided for @videoNotReady.
  ///
  /// In en, this message translates to:
  /// **'Video not ready'**
  String get videoNotReady;

  /// No description provided for @viewOnGithub.
  ///
  /// In en, this message translates to:
  /// **'View on GitHub'**
  String get viewOnGithub;

  /// No description provided for @viewOnce.
  ///
  /// In en, this message translates to:
  /// **'View Once'**
  String get viewOnce;

  /// No description provided for @viewOnce2.
  ///
  /// In en, this message translates to:
  /// **'View once'**
  String get viewOnce2;

  /// No description provided for @viewOnce3.
  ///
  /// In en, this message translates to:
  /// **'View once'**
  String get viewOnce3;

  /// No description provided for @viewOncePhoto.
  ///
  /// In en, this message translates to:
  /// **'View Once Photo'**
  String get viewOncePhoto;

  /// No description provided for @viewProfile.
  ///
  /// In en, this message translates to:
  /// **'View profile'**
  String get viewProfile;

  /// No description provided for @voiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get voiceMessage;

  /// No description provided for @voiceMessageCacheExpired.
  ///
  /// In en, this message translates to:
  /// **'Voice message cache expired'**
  String get voiceMessageCacheExpired;

  /// No description provided for @voiceMessageQueuedWillSendWhenPeerIs.
  ///
  /// In en, this message translates to:
  /// **'Voice message queued. Will send when peer is available.'**
  String get voiceMessageQueuedWillSendWhenPeerIs;

  /// No description provided for @voicePreview.
  ///
  /// In en, this message translates to:
  /// **'🎤 Voice'**
  String get voicePreview;

  /// No description provided for @waitingForGroupKey.
  ///
  /// In en, this message translates to:
  /// **'Waiting for group key…'**
  String get waitingForGroupKey;

  /// No description provided for @welcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get welcomeBack;

  /// No description provided for @welcomeBackDisplayname.
  ///
  /// In en, this message translates to:
  /// **'Welcome back, {displayName}'**
  String welcomeBackDisplayname(String displayName);

  /// No description provided for @welcomeToPrysm.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Prysm'**
  String get welcomeToPrysm;

  /// No description provided for @whenDisabledYouWontSendOrSeeTypingActivity.
  ///
  /// In en, this message translates to:
  /// **'When disabled, you won\'t send or see typing activity in chats.'**
  String get whenDisabledYouWontSendOrSeeTypingActivity;

  /// No description provided for @whenEnabledPeopleWhoAreNotInYour.
  ///
  /// In en, this message translates to:
  /// **'When enabled, people who are not in your contacts cannot message or call you directly.'**
  String get whenEnabledPeopleWhoAreNotInYour;

  /// No description provided for @whenEnabledRecentContactsAreNotifiedWhenYou.
  ///
  /// In en, this message translates to:
  /// **'When enabled, recent contacts are notified when you come online so they can deliver pending messages faster.'**
  String get whenEnabledRecentContactsAreNotifiedWhenYou;

  /// No description provided for @whenPanicPinIsUsed.
  ///
  /// In en, this message translates to:
  /// **'When panic PIN is used'**
  String get whenPanicPinIsUsed;

  /// No description provided for @whoSetMessagesToDisappearIn.
  ///
  /// In en, this message translates to:
  /// **'{who} set messages to disappear in '**
  String whoSetMessagesToDisappearIn(String who);

  /// No description provided for @whoTurnedOffDisappearingMessages.
  ///
  /// In en, this message translates to:
  /// **'{who} turned off disappearing messages'**
  String whoTurnedOffDisappearingMessages(String who);

  /// No description provided for @willSendAt.
  ///
  /// In en, this message translates to:
  /// **'Will send {label}'**
  String willSendAt(String label);

  /// No description provided for @wipeLocalDataAndContinue.
  ///
  /// In en, this message translates to:
  /// **'Wipe local data and continue'**
  String get wipeLocalDataAndContinue;

  /// No description provided for @wipeLocalKeys.
  ///
  /// In en, this message translates to:
  /// **'Wipe local keys'**
  String get wipeLocalKeys;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @youAreAdmin.
  ///
  /// In en, this message translates to:
  /// **'You are admin'**
  String get youAreAdmin;

  /// No description provided for @youAreNoLongerInThisGroup.
  ///
  /// In en, this message translates to:
  /// **'You are no longer in this group'**
  String get youAreNoLongerInThisGroup;

  /// No description provided for @youWillNoLongerReceiveMessagesCallsOr.
  ///
  /// In en, this message translates to:
  /// **'You will no longer receive messages, calls, or profile updates from this contact.'**
  String get youWillNoLongerReceiveMessagesCallsOr;

  /// No description provided for @yourId.
  ///
  /// In en, this message translates to:
  /// **'Your ID'**
  String get yourId;

  /// No description provided for @yourPassphraseProtectsYourKeys.
  ///
  /// In en, this message translates to:
  /// **'Your passphrase protects your keys'**
  String get yourPassphraseProtectsYourKeys;

  /// No description provided for @yourPinProtectsYourKeys.
  ///
  /// In en, this message translates to:
  /// **'Your PIN protects your keys'**
  String get yourPinProtectsYourKeys;

  /// No description provided for @yourPrysmId.
  ///
  /// In en, this message translates to:
  /// **'Your Prysm ID'**
  String get yourPrysmId;

  /// No description provided for @yourPrysmIdWillAppearOnceTorFinishes.
  ///
  /// In en, this message translates to:
  /// **'Your Prysm ID will appear once Tor finishes connecting.'**
  String get yourPrysmIdWillAppearOnceTorFinishes;

  /// No description provided for @chatMediaFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get chatMediaFilterAll;

  /// No description provided for @chatMediaFilterFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get chatMediaFilterFiles;

  /// No description provided for @chatMediaFilterPhotos.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get chatMediaFilterPhotos;

  /// No description provided for @chatMediaFilterVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get chatMediaFilterVoice;

  /// No description provided for @chooseATimeInTheFuture.
  ///
  /// In en, this message translates to:
  /// **'Choose a time in the future'**
  String get chooseATimeInTheFuture;

  /// No description provided for @deleteMediaFromConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{label}\" from {conversation}? This removes it from your device only.'**
  String deleteMediaFromConversation(String label, String conversation);

  /// No description provided for @groupInviteReceivedAt.
  ///
  /// In en, this message translates to:
  /// **'Group invite · {receivedAt}'**
  String groupInviteReceivedAt(String receivedAt);

  /// No description provided for @scheduleSendsAt.
  ///
  /// In en, this message translates to:
  /// **'Sends {label}'**
  String scheduleSendsAt(String label);

  /// No description provided for @sendHoldToSchedule.
  ///
  /// In en, this message translates to:
  /// **'Send. Hold to schedule'**
  String get sendHoldToSchedule;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @youWillNeedThisPasswordToRestore.
  ///
  /// In en, this message translates to:
  /// **'You will need this password to restore.'**
  String get youWillNeedThisPasswordToRestore;

  /// No description provided for @openWithSystemApp.
  ///
  /// In en, this message translates to:
  /// **'Open with system app'**
  String get openWithSystemApp;

  /// No description provided for @displayNameHintExample.
  ///
  /// In en, this message translates to:
  /// **'eg. Alice'**
  String get displayNameHintExample;

  /// No description provided for @showQrCode.
  ///
  /// In en, this message translates to:
  /// **'Show QR Code'**
  String get showQrCode;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'it'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'it':
      return AppLocalizationsIt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
