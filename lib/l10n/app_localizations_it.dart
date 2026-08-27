// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get aNewVersionIsAvailable => 'È disponibile una nuova versione.';

  @override
  String get aPanicPinIsASecondPasscodeEntering =>
      'Un panic PIN è un secondo passcode. Inserirlo allo sblocco ';

  @override
  String get about => 'Informazioni';

  @override
  String aboutApp(String appName) {
    return 'Informazioni su $appName';
  }

  @override
  String get aboutThisApp => 'Informazioni sull\'app';

  @override
  String get accept => 'Accetta';

  @override
  String get acceptCall => 'Accetta chiamata';

  @override
  String get activeCallsChannel => 'Chiamate in corso';

  @override
  String get activeCallsChannelDescription => 'Chiamate vocali in corso';

  @override
  String get add => 'Aggiungi';

  @override
  String get addContact => 'Aggiungi contatto';

  @override
  String get addContactAndJoin => 'Aggiungi contatto e partecipa';

  @override
  String get addContactOfflineHint =>
      'Connetti Tor per aggiungere contatti. Puoi saltare questo passaggio e aggiungere amici più tardi dall\'app.';

  @override
  String get addContactOnlineHint =>
      'Chiedi a un amico il Prysm ID (codice Base58 o QR). Deve essere online su Tor per la prima connessione.';

  @override
  String get addContactsBeforeCreatingAGroup =>
      'Aggiungi contactti prima di create un gruppo';

  @override
  String get addMember => 'Aggiungi membro';

  @override
  String get addYourFirstContact => 'Aggiungi il tuo primo contatto';

  @override
  String addedMemberWillReceiveInviteWhenOnline(String name) {
    return 'Aggiunto $name. Riceverà un invito quando sarà online.';
  }

  @override
  String get admin => 'Amministratore';

  @override
  String get advancedPrivacy => 'Privacy avanzata';

  @override
  String get after5FailedUnlockAttemptsLock2Hours =>
      'Dopo 5 tentativi di sblocco falliti, Prysm si blocca per 2 ore';

  @override
  String get alignTheQrCodeInsideTheFrameTo =>
      'Allinea il QR code all\'area per scannerizzare.';

  @override
  String get anInviteFromSomeoneWhoIsNotIn =>
      'Un invito da qualcuno che non è nei tuoi contatti è tenuto come ';

  @override
  String get appTitle => 'Prysm';

  @override
  String get appearance => 'Aspetto';

  @override
  String get archiveChat => 'Archivia chat';

  @override
  String get archived => 'Archiviate';

  @override
  String get areYouSureYouWantToDeleteAll =>
      'Sei sicuro di voler eliminare tutti i messaggi in questa chat? Questa azione non può essere annullata.';

  @override
  String get areYouSureYouWantToDeleteThis =>
      'Sei sicuro di voler eliminare questo contatto? Questa azione non può essere annullata.';

  @override
  String get askYourContactToShowThisCodeOr =>
      'Chiedi al tuo contatto di mostrare questo codice, o scannerizza il suo per verificare.';

  @override
  String get audioNotReady => 'Audio non pronto';

  @override
  String get autoRestarts => 'Riavvio-Automatico: ';

  @override
  String get autoRestartsLabel => 'Riavvii automatici:';

  @override
  String get back => 'Indietro';

  @override
  String get backToChats => 'Torna alle chat';

  @override
  String get backUpYourAccount => 'Esegui il backup del tuo account';

  @override
  String get backupCreateAnytimeInSettings =>
      'Puoi creare altri backup in qualsiasi momento in Impostazioni → Dati';

  @override
  String get backupCreated => 'Backup creato';

  @override
  String get backupEncryptedFileBullet =>
      'I backup sono file crittografati con password (.prysmbackup)';

  @override
  String backupFailedE(String e) {
    return 'Backup fallito: $e';
  }

  @override
  String get backupOnboardingBody =>
      'Un backup salva chat, contatti e chiavi crittografate. Senza backup, perdere il dispositivo o dimenticare il codice significa perdere tutto.';

  @override
  String get backupPassword => 'Password backup';

  @override
  String get backupRestoredPleaseRestartTheApp =>
      'Backup caricato! Riavvia l\'app.';

  @override
  String backupSavedTo(String path) {
    return 'Backup salvato in $path';
  }

  @override
  String get backupStoreOutsideDevice =>
      'Conserva il file in un luogo sicuro fuori da questo dispositivo';

  @override
  String batterySaverAutoEnabledBatteryAt(int level) {
    return 'Attivato automaticamente — batteria al $level%';
  }

  @override
  String get batterySaverAutoEnabledPowerSaverOn =>
      'Attivato automaticamente — risparmio energetico del dispositivo attivo';

  @override
  String batterySaverAutoEnablesAt(int threshold) {
    return 'Si attiva automaticamente con batteria al $threshold% o inferiore';
  }

  @override
  String get batterySaverReducesPolling =>
      'Riduce il polling e l\'attività in background';

  @override
  String get batterySaving => 'Risparmio batteria';

  @override
  String get biometricsNotSupportedOnThisPlatform =>
      'Biometria non supportata su questa piattaforma';

  @override
  String get block => 'Blocca';

  @override
  String get blockContact => 'Blocca contatto';

  @override
  String get blockContactBody => 'Non potrà inviarti messaggi.';

  @override
  String get blockContactQuestion => 'Bloccare il contatto?';

  @override
  String get blocked => 'Bloccati';

  @override
  String get blockedContacts => 'Contatti bloccati';

  @override
  String get blockedViewProfile => 'Bloccato · Vedi profilo';

  @override
  String get bugFindingFeatureSuggestions =>
      'Segnala bug & Suggerisci funzioni';

  @override
  String get builtOnTor => 'Basato su Tor';

  @override
  String get caches => 'Cache';

  @override
  String get cachesCleared => 'Cache svuotate';

  @override
  String get calculating => 'Calcolo in corso…';

  @override
  String get callBack => 'Richiama';

  @override
  String get callDuration => 'Durata';

  @override
  String get callHistory => 'Cronologia chiamate';

  @override
  String get callMicrophone => 'Microfono chiamata';

  @override
  String get callPreview => '📞 Chiamata';

  @override
  String get callStarted => 'Inizio';

  @override
  String get cameraPermissionRequired => 'Permesso fotocamera richiesto';

  @override
  String get cancel => 'Annulla';

  @override
  String get cancelMessage => 'Annulla messaggio';

  @override
  String get cancelScheduledMessage => 'Annullare il messaggio programmato?';

  @override
  String get changePanicPin => 'Cambia PIN panico';

  @override
  String get changePasscode => 'Cambia codice';

  @override
  String get changeUnlockMethodInSettingsPrivacy =>
      'Cambia il metodo di sblocco in Impostazioni → Privacy';

  @override
  String get chatMedia => 'Media chat';

  @override
  String get chatMedia2 => 'Media chat';

  @override
  String get chatMediaIsStoredEncryptedOnThisDevice =>
      'I media di questa chat sono salvati e cifrati sul tuo dispositivo. ';

  @override
  String get chatMediaStoredEncryptedDisclaimer =>
      'I media delle chat sono archiviati crittografati su questo dispositivo. Eliminarli qui li rimuove solo localmente — potrebbero ancora esistere per altri partecipanti.';

  @override
  String get chatWithMyself => 'Chat con me stesso';

  @override
  String get chatWithMyself6 => 'chat con me stesso';

  @override
  String get chats => 'Chat';

  @override
  String get checkForUpdates => 'Controlla aggiornamenti';

  @override
  String get checking => 'Controllo...';

  @override
  String get chooseANew6DigitPin => 'Scegli un nuovo PIN a 6 cifre.';

  @override
  String get chooseANewPassphraseAtLeast12Characters =>
      'Scegli una nuova passphrase (almeno 12 caratteri).';

  @override
  String get chooseAStrongPasswordToEncryptYourBackup =>
      'Scegli una passphrase forte per cifrare il tuo backup. ';

  @override
  String get chooseDownloadFolder => 'Scegli cartella download';

  @override
  String get chooseFolder => 'Scegli cartella';

  @override
  String get chooseYourUnlockMethod => 'Scegli il metodo di sblocco';

  @override
  String get clear => 'Svuota';

  @override
  String get clearCaches => 'Svuota cache';

  @override
  String get clearCallHistory => 'Cancella cronologia chiamate';

  @override
  String get clearHistory => 'Cancella cronologia';

  @override
  String get close => 'Chiudi';

  @override
  String get closeSearch => 'Chiudi ricerca';

  @override
  String get comingSoonNotWorking => 'PROSSIMAMENTE, NON FUNZIONANTE';

  @override
  String get completed => 'Completato';

  @override
  String get composerRounding => 'Arrotondamento compositore';

  @override
  String get confirm => 'Conferma';

  @override
  String get confirmNewPanicPin => 'Conferma nuovo PIN di emergenza';

  @override
  String get confirmNewPin => 'Conferma nuovo PIN';

  @override
  String get confirmPanicPin => 'Conferma PIN di emergenza';

  @override
  String get confirmPasscode => 'Conferma codice';

  @override
  String get confirmPassphrase => 'Conferma passphrase';

  @override
  String get confirmYourPin => 'Conferma il PIN';

  @override
  String get connectToTorBeforeAddingContacts =>
      'Connettiti a Tor prima di aggiungere contatti';

  @override
  String get connectTor => 'Connetti Tor';

  @override
  String get connectTorForPrysmId =>
      'Connettiti a Tor per vedere il tuo Prysm ID';

  @override
  String get connectViaOnionId => 'Connettiti via Onion ID';

  @override
  String get connected => 'Connesso';

  @override
  String get connecting => 'Connessione...';

  @override
  String get connecting2 => 'Connessione...';

  @override
  String get connecting3 => 'Connessione...';

  @override
  String get connecting4 => 'Connessione...';

  @override
  String connectingBootstrap(String bootstrap) {
    return 'Connessione ($bootstrap%)';
  }

  @override
  String get connectingToTor => 'Connessione a Tor…';

  @override
  String get contactAdded => 'Contatto aggiunto';

  @override
  String get contactAddedSuccessfully => 'Contatto aggiunto con successo';

  @override
  String contactCountSummary(int contactCount, int groupCount) {
    String _temp0 = intl.Intl.pluralLogic(
      contactCount,
      locale: localeName,
      other: '$contactCount contatti',
      one: '1 contatto',
    );
    String _temp1 = intl.Intl.pluralLogic(
      groupCount,
      locale: localeName,
      other: '$groupCount gruppi',
      one: '1 gruppo',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String get contactInfo => 'Info contatto';

  @override
  String get contactNotFound => 'Contatto non trovato';

  @override
  String get continueLabel => 'Continua';

  @override
  String get continueOffline => 'Continua offline';

  @override
  String get copiedToClipboard => 'Copiato negli appunti';

  @override
  String get copy => 'Copia';

  @override
  String get copyId => 'Copia ID';

  @override
  String get couldNotAddContact => 'Impossibile aggiungere contatto';

  @override
  String get couldNotChangeUnlockMethod =>
      'Impossibile cambiare il metodo di sblocco';

  @override
  String get couldNotConnectToPeerMessagesWillBe =>
      'Impossibile connettersi al peer. I messaggi verranno aggiunti alla coda.';

  @override
  String get couldNotCopy => 'Impossibile copiare';

  @override
  String get couldNotCreateGroupMakeSureAllMembers =>
      'Impossibile creare il gruppo. Assicurati che tutti i membri siano online e riprova.';

  @override
  String couldNotDeleteFileE(String e) {
    return 'Impossibile cancellare il file: $e';
  }

  @override
  String get couldNotDeleteForEveryone => 'Impossibile cancellare per tutti';

  @override
  String couldNotDeleteMediaE(String e) {
    return 'Impossibile cancellare media: $e';
  }

  @override
  String get couldNotEditMessage => 'Impossibile modificare il messaggio';

  @override
  String couldNotForwardE(String e) {
    return 'Impossibile inoltrare: $e';
  }

  @override
  String couldNotLoadDownloadsE(String e) {
    return 'Impossibile caricare i downloads: $e';
  }

  @override
  String get couldNotLoadImage => 'Impossibile copiare l\'immagine';

  @override
  String couldNotLoadMediaE(String e) {
    return 'Impossibile caricare i media: $e';
  }

  @override
  String get couldNotLoadPreview => 'Impossibile caricare l\'anteprima';

  @override
  String couldNotLoadStorageUsageE(String e) {
    return 'Impossibile caricare l\'utilizzo del disco: $e';
  }

  @override
  String couldNotOpenFileE(String e) {
    return 'Errore nell\'apertura del file: $e';
  }

  @override
  String couldNotOpenImageE(String e) {
    return 'Errore nell\'apertura dell\'immagine: $e';
  }

  @override
  String couldNotOpenSeparateWindowE(String e) {
    return 'Impossibile aprire una finestra dedicata: $e';
  }

  @override
  String couldNotOpenVideoE(String e) {
    return 'Impossibile caricare il video: $e';
  }

  @override
  String couldNotPlayVoiceMessageE(String e) {
    return 'Impossibile riprodurre il messaggio vocale: $e';
  }

  @override
  String couldNotReadDroppedFileE(String e) {
    return 'Impossibile leggere il file: $e';
  }

  @override
  String couldNotReadFileE(String e) {
    return 'Impossibile leggere il file: $e';
  }

  @override
  String get couldNotReadPresentationContentInPrysm =>
      'Impossibile caricare la presentazione in Prysm.';

  @override
  String get couldNotReadSpreadsheet => 'Impossibile caricare fogli di calcolo';

  @override
  String couldNotSaveImage(String e) {
    return 'Impossibile salvare l\'immagine: $e';
  }

  @override
  String couldNotScheduleMessageE(String e) {
    return 'Impossibile programmare il messaggio: $e';
  }

  @override
  String get couldNotSendFileGroupKeyUnavailable =>
      'Impossibile inviare il file — chiave del gruppo non disponibile';

  @override
  String get couldNotSendMessageGroupKeyUnavailable =>
      'Impossibile inviare il messaggio — chiave del gruppo non disponibile';

  @override
  String get couldNotSetUpPasscodeTryAgain =>
      'Impossibile configurare il codice. Riprova.';

  @override
  String get couldNotSetUpPassphraseMin12 =>
      'Impossibile configurare la passphrase. Usa almeno 12 caratteri.';

  @override
  String get couldNotSetUpPinTryAgain =>
      'Impossibile configurare il PIN. Riprova.';

  @override
  String couldNotStartCallE(String e) {
    return 'Impossibile chiamare: $e';
  }

  @override
  String get couldNotUpdateUnlockCode =>
      'Impossibile aggiornare il codice di sblocco';

  @override
  String count(String count) {
    return '$count';
  }

  @override
  String get create => 'Crea';

  @override
  String get createAnotherBackup => 'Crea un altro backup';

  @override
  String get createBackup => 'Crea backup';

  @override
  String get createBackupNow => 'Crea backup ora';

  @override
  String get createGroup => 'Crea Group';

  @override
  String get createGroup2 => 'Crea gruppo';

  @override
  String get createPassphrase => 'Crea Passphrase';

  @override
  String get createYourPin => 'Crea il PIN';

  @override
  String get cryptoUpgradeRequired => 'Aggiornamento crittografia richiesto';

  @override
  String get currentPanicPin => 'PIN di panico attuale';

  @override
  String get currentPassphrase => 'Passphrase attuale';

  @override
  String get currentPin => 'PIN attuale';

  @override
  String get cut => 'Taglia';

  @override
  String get cyanMode => 'Modalità ciano';

  @override
  String dMoYHMin(String d, String mo, String y, String h, String min) {
    return '$d/$mo/$y - $h:$min';
  }

  @override
  String get dangerZone => 'Zona pericolosa';

  @override
  String get darkMode => 'Modalità scura';

  @override
  String get data => 'Dati';

  @override
  String get debugOptions => 'Opzioni debug';

  @override
  String get decline => 'Rifiuta';

  @override
  String get declineCall => 'Rifiuta chiamata';

  @override
  String get declined => 'Rifiutato';

  @override
  String get decoyProfile => 'Profilo esca';

  @override
  String get defaultInput => 'Input predefinito';

  @override
  String get delete => 'Elimina';

  @override
  String get deleteAllMessagesInThisChat =>
      'Elimina tutti i messaggi in questa chat';

  @override
  String get deleteChat => 'Elimina Chat';

  @override
  String get deleteContact => 'Elimina contatto';

  @override
  String get deleteFile => 'Elimina file';

  @override
  String deleteFileFromDownloads(String fileName) {
    return 'Eliminare \"$fileName\" dai download?';
  }

  @override
  String get deleteForEveryone => 'Elimina per tutti';

  @override
  String get deleteGroup => 'Elimina gruppo';

  @override
  String get deleteMedia => 'Elimina media';

  @override
  String get deleteTemporaryImageAndVoiceCaches =>
      'Elimina cache temporanea voce e immagini? ';

  @override
  String get deleteThisContactFromYourListCannotBe =>
      'Eliminare il contatto? questa azione non può essere annullata.';

  @override
  String get deleteThisGroupForEveryoneThisCannotBe =>
      'Elimina il gruppo per tutti? questa azione non può essere annullata.';

  @override
  String get demoteAdmin => 'Rimuovi admin';

  @override
  String get deleted => 'Eliminato';

  @override
  String get delivered => 'Consegnato';

  @override
  String get delivery => 'Consegna';

  @override
  String get destroyKeysAndLocalDatabasesThenShowAn =>
      'Distruggi chiavi e database, Poi mostra l\'app vuota';

  @override
  String directionCallDuration(String direction, String duration) {
    return '$direction chiamata · $duration';
  }

  @override
  String directionCallStatus(String direction, String status) {
    return '$direction chiamata · $status';
  }

  @override
  String get disappearing1d => '1 giorno';

  @override
  String get disappearing1h => '1 ora';

  @override
  String get disappearing1w => '1 settimana';

  @override
  String get disappearing30s => '30 secondi';

  @override
  String get disappearing4w => '4 settimane';

  @override
  String get disappearing5m => '5 minuti';

  @override
  String get disappearing8h => '8 ore';

  @override
  String disappearingDurationDays(int count) {
    return '$count g';
  }

  @override
  String disappearingDurationHours(int count) {
    return '$count h';
  }

  @override
  String disappearingDurationMinutes(int count) {
    return '$count min';
  }

  @override
  String disappearingDurationSeconds(int count) {
    return '$count s';
  }

  @override
  String disappearingDurationWeeks(int count) {
    return '$count sett';
  }

  @override
  String get disappearingMessages => 'Messaggi effimeri';

  @override
  String get disappearingOff => 'Disattivato';

  @override
  String get disappearsAfterViewing => '🔒 Scompare dopo la visualizzazione';

  @override
  String get discard => 'Scarta';

  @override
  String get discardInvite => 'Rifiuta invito';

  @override
  String get disconnected => 'Disconnesso';

  @override
  String get diskUsageAndMediaManagement => 'Utilizzo disco e gestione media';

  @override
  String get dismiss => 'Chiudi';

  @override
  String get displayName => 'Nome mostrato';

  @override
  String get displayName2 => 'Nome mostrato';

  @override
  String get done => 'Fatto';

  @override
  String get download => 'Scarica';

  @override
  String get downloadAnyway => 'Scarica comunque';

  @override
  String downloadFailedE(String e) {
    return 'Download fallito: $e';
  }

  @override
  String get downloadFromGithubReleases => 'Scarica da GitHub releases';

  @override
  String get downloadLocation => 'Posizione download';

  @override
  String get downloadLocationResetToDefault =>
      'Destinazione di download re impostata alla standard';

  @override
  String get downloadRiskyFile => 'Scaricare file rischioso?';

  @override
  String get downloading => 'Scaricando...';

  @override
  String get downloads => 'Download';

  @override
  String get downloadsFolderNotAvailable => 'Cartella download non disponibile';

  @override
  String downloadsWillBeSavedToPath(String path) {
    return 'I download verranno salvati in $path';
  }

  @override
  String get dropToSend => 'Rilascia per inviare';

  @override
  String get edit => 'Modifica';

  @override
  String get editMessage => 'Modifica messaggio';

  @override
  String get editName => 'Moficia Nome';

  @override
  String get emergency => 'Emergenza';

  @override
  String get emptyFile => 'File vuoto';

  @override
  String get enableRelayServer => 'Abilita server relay';

  @override
  String get encryptionPrivacy => 'Crittografia e privacy';

  @override
  String get endToEndEncryption => '• Crittografia end-to-end';

  @override
  String get enterAGroupName => 'Inserisci un nome per il gruppo';

  @override
  String get enterAValidBase58PrysmId => 'Inserisci un Prysm ID Base58 valido ';

  @override
  String get enterBothIdAndDisplayName => 'Inserisci ID e nome mostrato';

  @override
  String get enterPanicPinToRemove => 'Inserisci PIN di panico per rimuovere';

  @override
  String get enterPasscode => 'Inserisci Passcode';

  @override
  String get enterPassphrase => 'Inserisci Passphrase';

  @override
  String get enterPassphraseOrPanicPin =>
      'Inserisci passphrase o PIN di emergenza';

  @override
  String get enterYourCurrentUnlockPassphrase =>
      'Inserisci la passphrase attuale.';

  @override
  String get enterYourCurrentUnlockPin =>
      'Inserisci il PIN di sblocco attuale.';

  @override
  String get export => 'Esporta';

  @override
  String get exportEncryptedBackupFile =>
      'Esporta il file di backup crittografato';

  @override
  String get exportLog => 'Esporta i log';

  @override
  String get failed => 'Non riuscito';

  @override
  String failedToCreateGroupE(String e) {
    return 'Impossibile creare del gruppo: $e';
  }

  @override
  String failedToExportLog(String e) {
    return 'Esportazione log non riuscita: $e';
  }

  @override
  String failedToExportLogE(String e) {
    return 'Esportazione log non riuscita: $e';
  }

  @override
  String get failedToPlayVoiceMessage =>
      'Impossibile riprodurre il messaggio vocale';

  @override
  String get failedToRefreshCircuit => 'Impossibile aggiornare il circuito';

  @override
  String get features => 'Funzionalità:';

  @override
  String get file => 'File';

  @override
  String get fileDeleted => 'File eliminato';

  @override
  String get fileIsStillDecryptingOrEmpty =>
      'Il file è ancora in decifratura o vuoto';

  @override
  String fileMayBeHarmfulOnlyDownloadIfTrusted(String fileName) {
    return '$fileName potrebbe essere dannoso per il dispositivo. Scarica solo se ti fidi del mittente.';
  }

  @override
  String get fileNotReadyToDownload => 'File non pronto per il download';

  @override
  String get filePreview => '📎 File';

  @override
  String get filePreviews => 'Anteprime file';

  @override
  String get filePreviewsInChatSubtitle =>
      'Mostra anteprime inline di documenti, immagini e media nella chat';

  @override
  String get filePreviewsSubtitle =>
      'Mostra anteprime inline per immagini e documenti';

  @override
  String get fileQueuedWillSendWhenPeerIsAvailable =>
      'File messo in coda. Verrà inviato quando il peer sarà online.';

  @override
  String get fileTooLargeToPreview => 'File troppo grande per la preview';

  @override
  String filenameMayBeHarmfulToYourDevice(String fileName) {
    return '$fileName potrebbe danneggiare il disposito. ';
  }

  @override
  String get fingerprint => 'Impronta digitale';

  @override
  String get fingerprintCopied => 'Impronta digitale copied';

  @override
  String get font => 'Carattere';

  @override
  String get fontIbmPlexSans => 'IBM Plex Sans';

  @override
  String get fontInter => 'Inter';

  @override
  String get fontJetBrainsMono => 'JetBrains Mono';

  @override
  String get fontSystem => 'Sistema';

  @override
  String get forward => 'Inoltra';

  @override
  String get forwarded => 'Inoltrato';

  @override
  String get galleryAccessDenied => 'Accesso alla galleria negato';

  @override
  String get general => 'Generale';

  @override
  String get getStarted => 'Inizia';

  @override
  String get gettingStarted => 'Per iniziare';

  @override
  String get goOnlineToSendAndReceiveMessages =>
      'Connetitti a internet per ricevere e inviare messaggi';

  @override
  String get group => 'Gruppo';

  @override
  String get groupChat => 'Chat di gruppo';

  @override
  String get groupInviteContactsOnlyDescription =>
      'Gli inviti da chiunque altro vengono scartati all\'arrivo: nulla viene salvato o mostrato.';

  @override
  String get groupInviteContactsOnlyTitle => 'Accetta solo inviti dai contatti';

  @override
  String get groupInviteHoldDescription =>
      'Un invito da qualcuno che non è nei tuoi contatti viene conservato come richiesta. Il dispositivo non lo contatta mai; aggiungerlo come contatto applica l\'invito.';

  @override
  String get groupCall => 'Chiamata di gruppo';

  @override
  String get groupCallInProgress => 'Chiamata in corso';

  @override
  String groupCallParticipantCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count partecipanti',
      one: '1 partecipante',
    );
    return '$_temp0';
  }

  @override
  String get groupInviteHoldTitle => 'Trattieni inviti da mittenti sconosciuti';

  @override
  String get groupInvites => 'Inviti di gruppo';

  @override
  String groupIsFullMax(String max) {
    return 'Gruppo pieno (max $max membri)';
  }

  @override
  String groupIsFullMaxgroupmembersMembersMax(String maxGroupMembers) {
    return 'Il gruppo è pieno. ($maxGroupMembers membri massimo)';
  }

  @override
  String get groupName => 'Nome gruppo';

  @override
  String get groupPhotoUpdated => 'Foto del gruppo aggiornata';

  @override
  String get groupRenamed => 'Gruppo rinominato';

  @override
  String get hangUp => 'Metti giù';

  @override
  String get healthCheck => 'Controllo stato operativo: ';

  @override
  String get healthCheckLabel => 'Controllo stato:';

  @override
  String get helpSupport => 'Aiuto & Supporto';

  @override
  String get hideEmojiPicker => 'Nascondi selettore emoji';

  @override
  String get hideToTrayWhenClickingMinimize =>
      'Nascondi nella barra di sistema quando clicchi il pulsante minimizza';

  @override
  String get holdInvitesFromUnknownSenders =>
      'Trattieni inviti da mittenti sconosciuti';

  @override
  String get holdToRecordAVoiceMessage =>
      'Tieni premuto per registrare un messaggio vocale';

  @override
  String hourMinutePeriod(String hour, String minute, String period) {
    return '$hour:$minute $period';
  }

  @override
  String get idCopiedToClipboard => 'ID copiato';

  @override
  String get idNotAvailable => 'ID non disponibile';

  @override
  String get identityVerification => 'Verifica dell\'identità';

  @override
  String get identityVerified => 'Identità verificata';

  @override
  String get image => '📷 Immagine';

  @override
  String get imageNotReadyToSave => 'Immagine non pronta per il salvataggio';

  @override
  String imageSavedFileName(String fileName) {
    return 'Immagine salvata ($fileName)';
  }

  @override
  String get importFromBackupFile => 'Importa file di backup';

  @override
  String get inAppPdfPreviewIsNotAvailableOn =>
      'Preview dei PDF In-app non è disponibile su questo dispositivo.';

  @override
  String get inCall => 'In chiamata';

  @override
  String get incoming => 'In arrivo';

  @override
  String get incomingCall => 'Chiamata in arrivo';

  @override
  String get incomingGroupCall => 'Chiamata di gruppo in arrivo';

  @override
  String get incomingCalls => 'Chiamate in arrivo';

  @override
  String get incomingCallsChannel => 'Chiamate in arrivo';

  @override
  String get incomingCallsChannelDescription =>
      'Squillo delle chiamate vocali in arrivo';

  @override
  String get incorrectPanicPin => 'PIN di panico sbagliato';

  @override
  String get incorrectPassphrase => 'Passphrase sbagliata';

  @override
  String get incorrectPin => 'PIN sbagliato';

  @override
  String get info => 'Info';

  @override
  String get installPermissionRequired =>
      'Autorizzazione installazione richiesta';

  @override
  String get invalidQrCode => 'QR code sbagliato';

  @override
  String get inviteRequests => 'Richieste di invito';

  @override
  String get invitesFromAnyoneElseAreDiscardedTheMoment =>
      'Inviti da chiunque altro sono rifiutati nel momento in cui arrivano: ';

  @override
  String get iosCameraUsage =>
      'Prysm ha bisogno della fotocamera per scansionare codici QR e aggiungere contatti.';

  @override
  String get iosMicrophoneUsage =>
      'Prysm ha bisogno del microfono per messaggi vocali e chiamate.';

  @override
  String get iosPhotoLibraryAddUsage =>
      'Prysm ha bisogno dell\'accesso per salvare immagini nella libreria foto.';

  @override
  String get iosPhotoLibraryUsage =>
      'Prysm ha bisogno dell\'accesso alla libreria foto quando condividi immagini nell\'app.';

  @override
  String get itWillNotBeSent => 'Non verrà inviato.';

  @override
  String get keep => 'Mantieni';

  @override
  String get keepPrysmRunningInTrayWhenClosing =>
      'Mantieni Prysm in esecuzione nella barra di sistema quando chiudi la finestra';

  @override
  String get keyChangedReVerify => 'Chiave cambiata, ri-verifica';

  @override
  String labelModKey(String label, String mod, String key) {
    return '$label ($mod+$key)';
  }

  @override
  String get language => 'Lingua';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageItalian => 'Italiano';

  @override
  String get languageSystem => 'Sistema';

  @override
  String get lastIssue => 'Ultimo invio: ';

  @override
  String get lastSeen => 'Ultimo accesso';

  @override
  String get later => 'Più tardi';

  @override
  String get leadDeveloper => 'Sviluppatore principale';

  @override
  String get joinCall => 'Entra nella chiamata';

  @override
  String get leaveAction => 'Esci';

  @override
  String get leaveCall => 'Esci dalla chiamata';

  @override
  String get leaveGroup => 'Lascia gruppo';

  @override
  String get leaveThisGroup => 'Lasciare questo gruppo?';

  @override
  String get legal => 'Note legali';

  @override
  String get lightMode => 'Modalità chiara';

  @override
  String get linkCopied => 'Link copiato';

  @override
  String get linkPreviews => 'Anteprime link';

  @override
  String get linkPreviewsSubtitle =>
      'Recupera metadati dei link quando invii URL';

  @override
  String get linkPreviewsViaTorSubtitle =>
      'Recupera titoli e immagini per gli URL nei messaggi tramite Tor';

  @override
  String get loading => 'Caricamento...';

  @override
  String get localDataError => 'Errore dati locali';

  @override
  String logSavedTo(String path) {
    return 'Log salvato in $path';
  }

  @override
  String get lookUp => 'Cerca';

  @override
  String get lookingUpContactOnTor => 'Cercando il contatto su Tor...';

  @override
  String get losePassphraseOnlyBackupRestores =>
      'Se perdi la passphrase, solo un backup può ripristinare l\'account';

  @override
  String get losePinOnlyBackupRestores =>
      'Se perdi il PIN, solo un backup può ripristinare l\'account';

  @override
  String get markAsVerified => 'Segna come verificato';

  @override
  String get markVerified => 'Segna come verificato';

  @override
  String maxMaxgroupmembersMembersTotal(String maxGroupMembers) {
    return 'Massimo $maxGroupMembers membri totali';
  }

  @override
  String get mediaDeleted => 'Media eliminato';

  @override
  String get member => 'Membro';

  @override
  String memberDisplayNameWithYou(String name, String youLabel) {
    return '$name ($youLabel)';
  }

  @override
  String membersCount(String count, String max) {
    return '$count / $max membri';
  }

  @override
  String get messageBubbleRounding => 'Arrotondamento bolle messaggi';

  @override
  String get messageHint => 'Messaggio';

  @override
  String get messageInfo => 'Informazioni messaggio';

  @override
  String get messagePinned => 'Messaggio fissato';

  @override
  String get messageUnpinned => 'Fissaggio rimosso';

  @override
  String get messageNotFoundInLoadedHistory =>
      'Messaggio non trovato nei messaggi caricati';

  @override
  String get messageQueuedWillSendWhenMembersAreReachable =>
      'Messaggio aggiunto alla coda. Verrà inviato quando i membri saranno online.';

  @override
  String get messageQueuedWillSendWhenPeerIsAvailable =>
      'Messaggio aggiunto alla coda. Verrà inviato quando il peer sarà disponibile.';

  @override
  String get messageShadows => 'Ombre messaggi';

  @override
  String get messages => 'Messaggi';

  @override
  String get microphoneLevel => 'Livello microfono';

  @override
  String get microphonePermissionDenied => 'Permesso microfono negato';

  @override
  String get minimizeToSystemTrayOnClose =>
      'Riduci a icona nella barra di sistema alla chiusura';

  @override
  String get minimizeToTrayOnClose => 'Riduci a icona alla chiusura';

  @override
  String get minimizeToTrayOnCloseSubtitle =>
      'Mantieni Prysm in esecuzione in background quando chiudi la finestra';

  @override
  String get minimizeToTrayWhenMinimizingWindow =>
      'Riduci a icona quando minimizzi la finestra';

  @override
  String get minimum12Characters => 'Minimo 12 caratteri';

  @override
  String minutesSeconds(String minutes, String seconds) {
    return '$minutes:$seconds';
  }

  @override
  String get missed => 'Persa';

  @override
  String get mockUpdateUiNoDownload =>
      'UI di aggiornamento simulato (no download)';

  @override
  String get moreReactions => 'Altre reazioni…';

  @override
  String mustBeAtLeastNCharacters(int minLength) {
    return 'Deve contenere almeno $minLength caratteri';
  }

  @override
  String get muteMember => 'Silenzia membro';

  @override
  String get muteNotifications => 'Silenzia notifiche';

  @override
  String get muted => 'Silenziato';

  @override
  String get mutedInGroup => 'Silenziato in questo gruppo';

  @override
  String mutedForDuration(String duration) {
    return 'per $duration';
  }

  @override
  String mutedUntilDateAndTime(String date, String time) {
    return 'Silenziate fino al $date, $time';
  }

  @override
  String mutedUntilTime(String time) {
    return 'Mutato fino a $time';
  }

  @override
  String get mutedUntilYouTurnNotificationsBackOn =>
      'Silenziato finché non riattivi le notifiche';

  @override
  String get myQrCode => 'Il mio QR Code';

  @override
  String get needsAttention => 'Richiede attenzione';

  @override
  String get network => 'Rete';

  @override
  String get neverSharePassphrase =>
      'Non condividere mai la passphrase con nessuno';

  @override
  String get neverSharePin => 'Non condividere mai il PIN con nessuno';

  @override
  String get newCircuit => 'Nuovo circuito';

  @override
  String get newMessage => 'Nuovo messaggio';

  @override
  String get newMessagesChannel => 'Nuovi messaggi';

  @override
  String get newMessagesChannelDescription =>
      'Canale notifiche per nuovi messaggi';

  @override
  String get newPanicPin => 'Nuovo PIN di panico';

  @override
  String get newPassphrase => 'Nuova passphrase';

  @override
  String get newPassphraseMustBeDifferent =>
      'La nuova passphrase deve essere diversa';

  @override
  String get newPin => 'Nuovo PIN';

  @override
  String get newPinMustBeDifferent => 'Il nuovo PIN deve essere diverso';

  @override
  String get newTorCircuitRequested => 'Nuovo circuito Tor richiesto';

  @override
  String get next => 'Avanti';

  @override
  String get nextMatch => 'Risultato successivo';

  @override
  String nextScheduleLabel(String label) {
    return 'Prossimo: $label';
  }

  @override
  String get no => 'No';

  @override
  String noBackupFilesFoundInLocation(String location) {
    return 'Nessun backup trovato in $location';
  }

  @override
  String get noBlockedContacts => 'Nessun contatto bloccato';

  @override
  String get noCallsYet => 'Nessuna chiamata per ora';

  @override
  String get noCentralServers => '• Nessun server centralizzato';

  @override
  String get noContactsAvailableToAdd =>
      'Nessun contatto disponibile da aggiungere';

  @override
  String get noConversationsFound => 'Nessuna conversazione trovata';

  @override
  String get noPinnedMessages => 'Nessun messaggio fissato';

  @override
  String get noDownloadedFiles => 'Nessun file scaricato';

  @override
  String get noEmojiFound => 'Nessuna emoji trovata';

  @override
  String get noForgotPassphraseRecovery =>
      'La passphrase non può essere recuperata se dimenticata.';

  @override
  String get noForgotPinRecovery =>
      'Il PIN non può essere recuperato se dimenticato.';

  @override
  String get noIdentityKeyIsStoredForThisContact =>
      'Nessuna chiave di identità è salvata per questo contatto.';

  @override
  String get noInviteRequests => 'Nessun invito';

  @override
  String get noLogFileFound => 'Nessun file di log trovato';

  @override
  String get noMediaInThisConversationYet =>
      'Nessun media in questa conversazione';

  @override
  String get noMediaStored => 'Nessun media salvato';

  @override
  String get noPreviewAvailable => 'Nessuna preview disponibile';

  @override
  String get noReadInformationAvailable =>
      'Nessuna informazione sulla lettura disponibile.';

  @override
  String get notVerified => 'Non verificato';

  @override
  String get notesToSelf => 'Note per me stesso';

  @override
  String get notesToYourself => 'Notes per te stesso';

  @override
  String get notifications => 'Notifiche';

  @override
  String notificationsEnabledForLabel(String label) {
    return 'Notifiche attivate per $label';
  }

  @override
  String get notificationsMuted => 'Notifiche silenziate';

  @override
  String notificationsMutedMuteduntilForLabel(String mutedUntil, String label) {
    return 'Notifiche disattivate fino $mutedUntil per $label';
  }

  @override
  String get notificationsSubtitle =>
      'Mostra avvisi per nuovi messaggi e chiamate';

  @override
  String get offline => 'Offline';

  @override
  String get offlineConnectLaterForPrysmId =>
      'Offline — connetti più tardi per ottenere il Prysm ID';

  @override
  String get offlinePrysmOrRetry =>
      'Puoi usare Prysm offline o riprovare quando hai una connessione.';

  @override
  String get ok => 'OK';

  @override
  String get onboardingIdBody =>
      'Questo è il tuo indirizzo unico su Tor. Gli amici lo usano per aggiungerti. È una codifica Base58 del tuo hidden service .onion.';

  @override
  String get onboardingIdShareHint =>
      'Condividi questo ID o QR per ricevere messaggi. Lo trovi sempre nel profilo o nella barra laterale.';

  @override
  String onboardingStepOf(String current, String total) {
    return 'Passo $current di $total';
  }

  @override
  String get onboardingTorBody =>
      'Prysm instrada tutto il traffico attraverso la rete Tor. I messaggi raggiungono i contatti direttamente — nessun server centrale memorizza le chat.';

  @override
  String get onboardingTorBulletMustConnect =>
      'Tor deve essere connesso prima di poter messaggiare';

  @override
  String get onboardingTorBulletOnionAddress =>
      'Il tuo indirizzo onion è la tua identità sulla rete';

  @override
  String get onboardingTorBulletStatusBar =>
      'Lo stato Tor nella barra dell\'app mostra la connessione';

  @override
  String get onboardingWelcomeSetupRequired =>
      'Scegli come sbloccare Prysm e proteggere le chiavi. Questa configurazione è necessaria prima di usare l\'app.';

  @override
  String get onboardingWelcomeTour =>
      'Messaggistica privata su Tor. Questo breve tour copre l\'essenziale per iniziare a chattare con sicurezza.';

  @override
  String onionAddress(String address) {
    return 'Onion: $address';
  }

  @override
  String get online => 'Online';

  @override
  String get onlyAdminsCanAddMembers =>
      'Solo admin e proprietario possono aggiungere membri';

  @override
  String get onlyAcceptInvitesFromContacts =>
      'Accetta solo inviti dai contatti';

  @override
  String get onlyDownloadIfYouTrustTheSender =>
      'Scarica solo se ti fidi del mittente.';

  @override
  String get onlyMarkContactVerifiedIfComparedFull =>
      'Segna questo contatto come verificato solo se hai confrontato la sua impronta di persona o tramite un canale attendibile.';

  @override
  String get onlyMarkThisContactAsVerifiedIfYou =>
      'Segna questo contatto come verificato se hai confrontato la sua ';

  @override
  String get onlyOneFileAtATime => 'Solo un file alla volta';

  @override
  String get openInASeparateWindow => 'Apri in una finestra dedicata';

  @override
  String get openMenu => 'Apri menu';

  @override
  String get openNotification => 'Apri notifica';

  @override
  String get openSettings => 'Apri impostazioni';

  @override
  String get openSettingsToAllowInstalls =>
      'Apri Impostazioni per consentire a Prysm di installare aggiornamenti.';

  @override
  String get openSource => '• Apri source';

  @override
  String get openToViewTheMessage => 'Apri per visualizzare il messaggio';

  @override
  String get openWithSystemPlayer => 'Apri con lettore di sistema';

  @override
  String get opened => 'Aperto';

  @override
  String get opening => 'Apertura…';

  @override
  String get orangeMode => 'Modalità arancione';

  @override
  String get originalMessageUnavailable =>
      'Messaggio originale non disponibile';

  @override
  String get otherAppData => 'Altri dati dell\'app';

  @override
  String get outboundQueueDepth => 'Profondità coda in uscita: ';

  @override
  String get outboundQueueDepthLabel => 'Profondità coda in uscita:';

  @override
  String get owner => 'Proprietario';

  @override
  String get outgoing => 'In uscita';

  @override
  String get panicDecoyDescription =>
      'Mostra un\'app vuota mentre i dati reali restano crittografati sul disco';

  @override
  String get panicDecoyTitle => 'Profilo esca';

  @override
  String get panicMode => 'Modalità panico';

  @override
  String get panicPinCannotMatchYourMainPasscode =>
      'PIN di panico non può essere uguale al tuo passcode principale';

  @override
  String get panicPinConfigured => 'PIN panico configurato';

  @override
  String get panicPinExplanationBody =>
      'Un PIN di emergenza è un secondo codice. Inserirlo allo sblocco non rivela mai le tue chat reali. Configura cosa succede quando viene usato.';

  @override
  String get panicPinIsSet => 'PIN di emergenza impostato';

  @override
  String get panicPinNotSet => 'PIN di emergenza non impostato';

  @override
  String get panicPinRemoved => 'PIN di emergenza rimosso';

  @override
  String get panicPinSaved => 'PIN di emergenza salvato';

  @override
  String get panicPinUpdated => 'PIN di emergenza aggiornato';

  @override
  String get panicWipeDescription =>
      'Distrugge chiavi e database locali, poi mostra un\'app vuota';

  @override
  String get panicWipeTitle => 'Cancella chiavi locali';

  @override
  String get passphrase => 'Passphrase';

  @override
  String get passphrase12Characters => 'Passphrase (12+ caratteri)';

  @override
  String get passphraseCannotMatchYourPanicPin =>
      'La passphrase non può essere uguale al tuo panic PIN';

  @override
  String get passphraseEncryptsKeysBody =>
      'La passphrase crittografa le chiavi private su questo dispositivo — Prysm non le vede né le memorizza nel cloud.';

  @override
  String get passphraseMustBeAtLeast12Characters =>
      'La passphrase deve essere almeno 12 caratteri';

  @override
  String get passphraseUpdated => 'Passphrase aggiornata';

  @override
  String get passphrasesDoNotMatch => 'Le passphrase non corrispondono';

  @override
  String get passwordMustBeAtLeast4Characters =>
      'La password deve essere almeno 4 caratteri';

  @override
  String get paste => 'Incolla';

  @override
  String get pdfDocument => 'Documento PDF';

  @override
  String get peerIsMuted => 'Il peer è mutato';

  @override
  String get pending => 'In attesa';

  @override
  String personIsTyping(String name) {
    return '$name sta scrivendo…';
  }

  @override
  String get photo => 'Foto';

  @override
  String get photoDisappearsAfterTheRecipientOpensIt =>
      'La foto si cancella dopo che il destinatario la apre';

  @override
  String get photoPreview => '📷 Foto';

  @override
  String get pickAConversationFromTheSidebarOrStart =>
      'Scegli una conversazione dalla barra laterale o iniziane una nuova.';

  @override
  String get pickConversationFromSidebar =>
      'Scegli una conversazione dalla barra laterale o iniziane una nuova.';

  @override
  String get pickOneMethodYouCanChangeItLater =>
      'Scegli un metodo. Potrai cambiarlo più tardi nelle Impostazioni.';

  @override
  String get pin => 'Fissa';

  @override
  String get pinCannotMatchYourPanicPin =>
      'Il PIN non può essere uguale al tuo PIN di panico';

  @override
  String get pinChat => 'Fissa chat';

  @override
  String get pinEncryptsKeysBody =>
      'Il PIN a 6 cifre crittografa le chiavi private su questo dispositivo — Prysm non le vede né le memorizza nel cloud.';

  @override
  String get pinMustBe6Digits => 'Il PIN deve avere 6 cifre';

  @override
  String get pinUpdated => 'PIN aggiornato';

  @override
  String get pinkMode => 'Modalità rosa';

  @override
  String get pinsDoNotMatch => 'I PIN non corrispondono';

  @override
  String get pinnedMessages => 'Messaggi fissati';

  @override
  String get presentation => 'Presentazione';

  @override
  String get previewUnavailable => 'Preview non disponibile';

  @override
  String get previewUnavailableFileTooLarge =>
      'Preview non disponibile (file troppo grande)';

  @override
  String get previewUpdateDialog => 'Anteprima finestra aggiornamento';

  @override
  String get previousMatch => 'Risultato precedente';

  @override
  String get promoteToAdmin => 'Promuovi ad admin';

  @override
  String get privacy => 'Privacy';

  @override
  String get privacyInformation => 'Informazioni sulla privacy';

  @override
  String get privacySettings => 'Impostazioni privacy';

  @override
  String privacySettingsBody(String appName) {
    return 'Queste impostazioni ti aiutano a controllare la privacy su $appName. Le scelte si applicano a tutte le conversazioni.';
  }

  @override
  String get profile => 'Profilo';

  @override
  String get profilePhoto => 'Foto profilo';

  @override
  String get prysm03UsesNewEndToEnd =>
      'Prysm 0.3 usa una nuova crittografia end-to-end (Curve25519 + AEAD). ';

  @override
  String get prysmCouldNotOpenItsLocalDatabaseThis =>
      'Prysm non è riuscito a caricare il database. Questo può succedere ';

  @override
  String get prysmIdBase58Label => 'Prysm ID (Base58)';

  @override
  String get prysmIdCopied => 'Prysm ID copiato';

  @override
  String get prysmIdCopiedToClipboard => 'Prysm ID copiato';

  @override
  String get prysmIdHintExample => 'es. 51EsbujFRDJLHJ';

  @override
  String get prysmNeedsCameraAccessToScanQrCodes =>
      'Prysm usa la fotocamera per scannerizzare i QR codes per aggiungere i contatti.';

  @override
  String get purpleMode => 'Modalità viola';

  @override
  String get qrScanCompareFingerprintManually =>
      'La scansione QR è supportata solo su dispositivi mobili. Confronta l\'impronta manualmente e usa \"Segna come verificato\".';

  @override
  String get qrScanner => 'QR Scanner';

  @override
  String get qrScannerIsOnlySupportedOnMobileDevices =>
      'Il QR Scanner è supportato solo su telefono (Android/iOS).';

  @override
  String get qrScanningIsOnlySupportedOnMobileDevices =>
      'La scannerizzazione QR è supportata solo su telefono. ';

  @override
  String get quit => 'Esci';

  @override
  String get read => 'Letto';

  @override
  String get readBy => 'Letto da';

  @override
  String get readReceipts => 'Conferme di lettura';

  @override
  String get receivedPreview => 'Anteprima ricevuti';

  @override
  String get recentTorLog => 'Log Tor recente';

  @override
  String get recording => 'Registrando...';

  @override
  String get refreshTorCircuit => 'Aggiorna circuito Tor';

  @override
  String get refuseMessagesFromNonContacts =>
      'Rifiuta messaggi da non-contatti';

  @override
  String get refuseNonContactsSubtitle =>
      'Se attivato, chi non è nei contatti non può inviarti messaggi diretti.';

  @override
  String get remove => 'Rimuovi';

  @override
  String get removeMember => 'Rimuovi membro';

  @override
  String removeMemberFromGroupQuestion(String name) {
    return 'Rimuovere $name dal gruppo?';
  }

  @override
  String get removePanicPin => 'Remove PIN di panico';

  @override
  String get removeVerification => 'Rimuovi verifica';

  @override
  String get renameGroup => 'Rinomina gruppo';

  @override
  String get replayTheSetupTour => 'Mostra il setup';

  @override
  String get reply => 'Rispondi';

  @override
  String get requestANewCircuitWhenConnectionsAreStuck =>
      'Richiedi un nuovo circuito quando le connessioni sono bloccate';

  @override
  String requestCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count richieste',
      one: '1 richiesta',
    );
    return '$_temp0';
  }

  @override
  String get reset => 'Reimposta';

  @override
  String get resetAllSettings => 'Reimpostare tutte le Impostazioni?';

  @override
  String get resetLocalDataAndContinue => 'Reimposta dati locali e continua';

  @override
  String get resetSettings => 'Reimposta impostazioni';

  @override
  String get restartTor => 'Riavvia Tor';

  @override
  String get restore => 'Ripristina';

  @override
  String get restoreBackup => 'Ripristina da backup';

  @override
  String get restoreDefaultSettings => 'Ripristina impostazioni predefinite';

  @override
  String restoreFailedE(String e) {
    return 'Ripristinio fallito: $e';
  }

  @override
  String get restoreFailedWrongPasswordOrCorruptFile =>
      'Ripristinio fallito, password sbagliata o file corrotto';

  @override
  String get retry => 'Riprova';

  @override
  String get retryCall => 'Riprova chiamata';

  @override
  String get ringing => 'Squillo...';

  @override
  String get save => 'Salva';

  @override
  String get saveDebugLogToDownloads =>
      'Salva log di debug nella cartella download';

  @override
  String get saveImage => 'Salva immagine';

  @override
  String get savePassphrase => 'Salva passphrase';

  @override
  String savedFileName(String fileName) {
    return 'Salvato $fileName';
  }

  @override
  String get savedToGallery => 'Salvato nella galleria';

  @override
  String get savedToPhotos => 'Salvato in Foto';

  @override
  String get scanContactQr => 'Scannerizza il QR del contatto';

  @override
  String get scanNotAvailable => 'Scanner non disponibile';

  @override
  String get scanQr => 'Scansiona QR';

  @override
  String get scanQrCode => 'Scansiona codice QR';

  @override
  String get scanText => 'Scannerizza testo';

  @override
  String get scannedQrDoesNotMatchContact =>
      'Il codice QR scansionato non corrisponde all\'identità di questo contatto. Potrebbe trattarsi di impersonificazione.';

  @override
  String get schedule => 'Programma';

  @override
  String scheduleDateAt(String date, String time) {
    return '$date alle $time';
  }

  @override
  String get scheduleMessage => 'Programma messaggio';

  @override
  String scheduleTodayAt(String time) {
    return 'Oggi alle $time';
  }

  @override
  String scheduleTomorrowAt(String time) {
    return 'Domani alle $time';
  }

  @override
  String scheduleWeekdayAt(String weekday, String time) {
    return '$weekday alle $time';
  }

  @override
  String get scheduledMessageCancelled => 'Messaggio programmato cancellato';

  @override
  String get scheduledMessages => 'Messaggi programmati';

  @override
  String get search => 'Cerca';

  @override
  String get searchArchived => 'Cerca archiviate...';

  @override
  String get searchBlocked => 'Cerca bloccati...';

  @override
  String get searchEmoji => 'Cerca emoji';

  @override
  String get searchInChat => 'Cerca nella chat...';

  @override
  String get searchWeb => 'Cerca sul web';

  @override
  String get secondaryPinIsActive => 'PIN secondario attivo';

  @override
  String get securityTeam => 'Team sicurezza';

  @override
  String get select => 'Seleziona';

  @override
  String get selectAll => 'Seleziona tutto';

  @override
  String get selectAtLeastOneMember => 'Seleziona almeno un membro';

  @override
  String get selectBackup => 'Seleziona backup';

  @override
  String get selectBackupFile => 'Seleziona file di backup';

  @override
  String get selectedFolderDoesNotExist => 'La cartella selezionata non esiste';

  @override
  String get sendPhoto => 'Invia photo';

  @override
  String get sendViewOnce => 'Invia visualizzazione singola';

  @override
  String senderNameNewMessage(String senderName) {
    return '$senderName: Nuovo messaggio';
  }

  @override
  String get sentPreview => 'Anteprima inviati';

  @override
  String sentTo(String name) {
    return 'Inviato a $name';
  }

  @override
  String get setAPanicPin =>
      'Imposta un PIN di emergenza per cancellare rapidamente o mostrare un profilo fittizio.';

  @override
  String get setPanicPin => 'Imposta PIN di panico';

  @override
  String get setPanicPinToEnablePanicMode =>
      'Imposta un PIN di emergenza per attivare la modalità panico';

  @override
  String get setSecondaryPanicPin => 'Imposta un PIN panico secondario';

  @override
  String get setUpPrysm => 'Configura Prysm';

  @override
  String get settings => 'Impostazioni';

  @override
  String get settingsResetToDefaults => 'Impostazioni reimpostate';

  @override
  String get settingsTitle => 'Impostazioni';

  @override
  String get setupPasscode => 'Imposta Passcode';

  @override
  String get severalPeopleAreTyping => 'Più persone stanno scrivendo';

  @override
  String get shadowStrength => 'Intensità ombra';

  @override
  String get shareThisIdOrQrSoOthersCan =>
      'Condividi questo ID o QR cosi che altri ti possano scrivere. Puoi sempre ';

  @override
  String get shareThisQrCodeWithOthersSoThey =>
      'Condividi questo QR code con altri per farti aggiungere come contatto.';

  @override
  String get shareToPrysm => 'Condividi su Prysm';

  @override
  String get sharedMedia => 'Media condivisi';

  @override
  String get showAnEmptyAppWhileYourRealData =>
      'Mostra l\'app vuota mentre i dati reali rimangono cifrati sul disco';

  @override
  String get showAsForwarded => 'Mostra come inoltrato';

  @override
  String get showFullQr => 'Mostra QR completo';

  @override
  String get showInChat => 'Mostra in chat';

  @override
  String get showMyQrCode => 'Mostra il mio codice QR';

  @override
  String get showNotificationsForNewMessages =>
      'Mostra notifiche per i nuovi messaggi';

  @override
  String get showOnlineStatus => 'Mostra stato online';

  @override
  String get showPrysm => 'Mostra Prysm';

  @override
  String get showQr => 'Mostra QR';

  @override
  String get silenceMessageAlerts => 'Silenzia avvisi messaggi';

  @override
  String get skipForNow => 'Salta per now';

  @override
  String get skipPinOrPassphraseUsingBiometrics =>
      'Salta PIN o passphrase usando impronta o volto';

  @override
  String get skipTour => 'Salta tour';

  @override
  String get skipVersionCheckDesktopDryRun =>
      'Salta controllo versione (desktop dry-run)';

  @override
  String get slidePreviewIsNotSupportedForThisFormat =>
      'Preview non supportata per questo format in Prysm.';

  @override
  String get sourceCode => 'Codice sorgente';

  @override
  String get spreadsheet => 'Foglio di calcolo';

  @override
  String get startMinimized => 'Avvia ridotto';

  @override
  String get startMinimizedSubtitle =>
      'Avvia Prysm nascosto nella barra di sistema';

  @override
  String get stopMessagesCallsAndProfileUpdates =>
      'Blocca messaggi, chiamate e aggiornamenti del profilo';

  @override
  String get storageManager => 'Gestione spazio';

  @override
  String get storageManagerUnavailable =>
      'Gestore dello spazio non disponibile';

  @override
  String get storageUsage => 'Utilizzo spazio';

  @override
  String get str1day => '1 giorno';

  @override
  String get str1hour => '1 ora';

  @override
  String get str1week => '1 settimana';

  @override
  String get str2hours => '2 ore';

  @override
  String get str30seconds => '30 secondi';

  @override
  String get str4hours => '4 ore';

  @override
  String get str4weeks => '4 settimane';

  @override
  String get str5minutes => '5 minuti';

  @override
  String get str6digitpin => 'PIN a 6 cifre';

  @override
  String get str8hours => '8 ore';

  @override
  String get switchingMethodsRequiresSettingANewUnlockCode =>
      'Il cambio del metodo richiede un nuovo codice di sblocco.';

  @override
  String get systemDefault => 'Default di sistema';

  @override
  String get tapToAllowMessagesAndCallsAgain =>
      'Tocca per consentire di nuovo messaggi e chiamate';

  @override
  String get tapToChangeGroupPhoto => 'Clicca per cambiare la foto del gruppo';

  @override
  String get tapToCopy => 'Clicca per copiare';

  @override
  String get tapToRename => 'Clicca per rinominare';

  @override
  String get tapToRetry => 'Clicca per riprovare';

  @override
  String get tapToSetGroupPhoto => 'Clicca per impostare la foto del gruppo';

  @override
  String get tapToView => 'Tocca per visualizzare';

  @override
  String get testUpdateFlow => 'Prova flusso aggiornamento';

  @override
  String get testersTeam => 'Team dei tester';

  @override
  String get textSize => 'Dimensione testo';

  @override
  String get theLogFileMayContainSensitiveInformationOnly =>
      'Il file dei log potrebbe contenere informazioni sensibili. Condividilo solo con chi ti fidi.';

  @override
  String get theScannedQrCodeDoesNotMatchThis =>
      'Il QR code scannerizzato non combacia con l\'identità del contatto. ';

  @override
  String get theirQrCode => 'Il suo QR code';

  @override
  String get thisContactWillBeAbleToMessageAnd =>
      'Questo contatto sarà in grado di messaggiarti e chiamarti nuovamente.';

  @override
  String get thisContactWillNoLongerBeMarkedAs =>
      'Questo contatto non verrà più mostrato come verificato.';

  @override
  String get thisIsYourSecondaryPinForEmergencyUse =>
      'Questo è il tuo PIN secondario in caso di emergenza.';

  @override
  String get thisIsYourUniqueAddressOnTorFriends =>
      'Questo è il tuo indirizzo univoco su Tor. Gli amici lo useranno per aggiungerti. ';

  @override
  String get thisQrCodeIsNotAValidPrysm =>
      'Questo QR code non è una identità Prysm valida.';

  @override
  String get thisRequestWillBeRemoved => 'Questa richiesta sarà rimossa.';

  @override
  String get thisWillPermanentlyDeleteAllCallLogs =>
      'Questo cancellerà per sempre la cronologia delle chiamate.';

  @override
  String get thisWillReplaceAllCurrentDataWithThe =>
      'Questo rimpiazzerà i dati con quelli del backup. L\'app verrà riavviata in seguito.';

  @override
  String get thisWillRestoreAllSettingsToTheirDefault =>
      'Questo ripristinerà tutte le impostazioni ai loro valori di default. Questa azione non può essere annullata.';

  @override
  String todayAtTime(String time) {
    return 'Oggi alle $time';
  }

  @override
  String get tomorrow => 'Domani';

  @override
  String tomorrowAtTime(String time) {
    return 'Domani alle at $time';
  }

  @override
  String torBootstrapPercent(String percent) {
    return 'Tor: $percent%';
  }

  @override
  String get torConnection => 'Connessione Tor';

  @override
  String get torIsConnected => 'Tor è connesso';

  @override
  String get torIsConnecting => 'Tor in connessione…';

  @override
  String get torNeedsAttentionAutomaticRecoveryPaused =>
      'Tor richiede attenzione — correzione automatica in pausa. ';

  @override
  String get torNetworkRouting => '• Routing della rete Tor';

  @override
  String torRestartFailedE(String e) {
    return 'Riavvio di Tor fallito: $e';
  }

  @override
  String get torRestartedSuccessfully => 'Tor riavviato con successo';

  @override
  String get torStatusConnected => 'Connesso';

  @override
  String get torStatusConnecting => 'Connessione';

  @override
  String torStatusConnectingPercent(String percent) {
    return 'Connessione ($percent)';
  }

  @override
  String get torStatusOff => 'Spento';

  @override
  String get total => 'Totale';

  @override
  String trayPendingMessage(int count) {
    return 'In attesa: $count messaggio';
  }

  @override
  String trayPendingMessages(int count) {
    return 'In attesa: $count messaggi';
  }

  @override
  String trayPendingShort(int count) {
    return '$count in attesa';
  }

  @override
  String trayTooltipBase(String status) {
    return 'Prysm · Tor $status';
  }

  @override
  String trayUnreadCount(int count) {
    return 'Non letti: $count';
  }

  @override
  String get transferOwnership => 'Trasferisci proprietà';

  @override
  String transferOwnershipTo(String name) {
    return 'Trasferire la proprietà a $name?';
  }

  @override
  String trayUnreadShort(int count) {
    return '$count non letti';
  }

  @override
  String get turnNotificationsBackOn => 'Riattiva notifiche';

  @override
  String twoPeopleAreTyping(String first, String second) {
    return '$first e $second stanno scrivendo…';
  }

  @override
  String get typingIndicators => 'Indicatori di scrittura';

  @override
  String get uiUxTeam => 'Team UI/UX';

  @override
  String get unableToDecryptMessage => 'Impossibile decifrare il messaggio';

  @override
  String get unarchiveChat => 'Ripristina chat';

  @override
  String get unblock => 'Sblocca';

  @override
  String get unblockContact => 'Sblocca contatto';

  @override
  String get unblockContactBody => 'Potrà inviarti messaggi di nuovo.';

  @override
  String get unblockContactQuestion => 'Sbloccare il contatto?';

  @override
  String get unblockToSendMessages => 'Sblocca per inviare messaggi';

  @override
  String get unknown => 'Sconosciuto';

  @override
  String get unlock => 'Sblocca';

  @override
  String get unlockMethod => 'Metodo di sblocco';

  @override
  String get unlockMethodConfigured => 'Metodo di sblocco configurato';

  @override
  String get unlockMethodSaved => 'Metodo di sblocco salvato';

  @override
  String get unlockMethodSetTo6DigitPin =>
      'Metodo di sblocco impostato su PIN a 6 cifre';

  @override
  String get unlockMethodSetToPassphrase =>
      'Metodo di sblocco impostato su passphrase';

  @override
  String get unlockPrysm => 'Sblocca Prysm';

  @override
  String get unlockWithBiometrics => 'Sblocca con biometria';

  @override
  String get unlockWithBiometricsSubtitle =>
      'Usa impronta o volto per sbloccare';

  @override
  String get unlocking => 'Sbloccando...';

  @override
  String get unpin => 'Rimuovi fissaggio';

  @override
  String get unpinChat => 'Rimuovi fissaggio';

  @override
  String get unmuteMember => 'Riattiva membro';

  @override
  String get untilITurnItBackOn => 'Finché non le riattivo';

  @override
  String get untilYouTurnThemBackOn => 'finché non le riattivi';

  @override
  String get upTo5Members => 'Fino a 5 memberi';

  @override
  String updateAvailable(String tagName) {
    return 'Aggiornamento disponibile ($tagName)';
  }

  @override
  String updateAvailableTagname(String tagName) {
    return 'Aggiornamento disponibile ($tagName)';
  }

  @override
  String get updateNow => 'Aggiorna ora';

  @override
  String get updateUnlockPassphraseSubtitle =>
      'Aggiorna la passphrase di sblocco senza cambiare la tua identità';

  @override
  String get updateUnlockPinSubtitle =>
      'Aggiorna il PIN di sblocco senza cambiare la tua identità';

  @override
  String get updatesAreNotAvailableOnIos =>
      'Aggiornamenti automatici non disponibili iOS.';

  @override
  String get updatingPrysm => 'Aggiornamento Prysm';

  @override
  String get uploadFile => 'Carica file';

  @override
  String get uploadImage => 'Carica Image';

  @override
  String get useFingerprintOrFace => 'Usa impronta o volto';

  @override
  String get usePasscode => 'Usa codice';

  @override
  String get useSystemDefault => 'Usa impostazione di sistema';

  @override
  String get userId => 'ID utente';

  @override
  String get userIdBase58OnionUrl => 'ID utente (URL Onion Base58)';

  @override
  String get userInterfaceDesign => 'Design interfaccia utente';

  @override
  String get verificationFailed => 'Verifica fallita';

  @override
  String get verificationRemoved => 'Verifica rimossa';

  @override
  String get verified => 'Verificato';

  @override
  String versionLabel(String version) {
    return 'Versione $version';
  }

  @override
  String get video => 'Video';

  @override
  String get videoNotReady => 'Video non pronto';

  @override
  String get viewOnGithub => 'Vedi su GitHub';

  @override
  String get viewOnce => 'Una visualizzazione';

  @override
  String get viewOnce2 => 'Visualizza una volta';

  @override
  String get viewOnce3 => 'Visualizza una volta';

  @override
  String get viewOncePhoto => 'Foto visualizzazione singola';

  @override
  String get viewProfile => 'Visualizza profilo';

  @override
  String get voiceMessage => 'Messaggio vocale';

  @override
  String get voiceMessageCacheExpired => 'Cache del messaggio vocale scaduta';

  @override
  String get voiceMessageQueuedWillSendWhenPeerIs =>
      'Messaggio vocale aggiunto alla coda. Verrà inviato quando il peer sarà online.';

  @override
  String get voicePreview => '🎤 Vocale';

  @override
  String get waitingForGroupKey => 'In attesa della chiave del gruppo...';

  @override
  String get welcomeBack => 'Bentornato';

  @override
  String welcomeBackDisplayname(String displayName) {
    return 'Bentornato, $displayName';
  }

  @override
  String get welcomeToPrysm => 'Benvenuto in Prysm';

  @override
  String get whenDisabledYouWontSendOrSeeTypingActivity =>
      'Se disattivato, non invierai né vedrai l\'attività di digitazione nelle chat.';

  @override
  String get whenEnabledPeopleWhoAreNotInYour =>
      'Quando attivato, le persone che non sono nei tuoi contatti non potranno messaggiarti o chiamarti direttamente.';

  @override
  String get whenEnabledRecentContactsAreNotifiedWhenYou =>
      'Quando attivato, i contatti recenti vengono notificati quando sei online così che i messaggi in coda ti arrivino più veloce.';

  @override
  String get whenPanicPinIsUsed => 'Quando il PIN di panico viene usato ';

  @override
  String whoSetMessagesToDisappearIn(String who) {
    return '$who ha impostato i messaggi effimeri per ';
  }

  @override
  String whoTurnedOffDisappearingMessages(String who) {
    return '$who ha disattivato i messaggi effimeri';
  }

  @override
  String willSendAt(String label) {
    return 'Invio alle $label';
  }

  @override
  String get wipeLocalDataAndContinue => 'Cancella dati e continue';

  @override
  String get wipeLocalKeys => 'Cancella chiavi locali';

  @override
  String get yes => 'Sì';

  @override
  String get you => 'Tu';

  @override
  String get youAreAdmin => 'Sei amministratore';

  @override
  String get youAreListenOnly =>
      'Sei silenziato in questo gruppo — solo ascolto';

  @override
  String get youAreMuted => 'Sei silenziato in questo gruppo';

  @override
  String get youAreNoLongerInThisGroup => 'Non fai più parte di questo gruppo';

  @override
  String get youAreOwner => 'Sei il proprietario';

  @override
  String get youWillNoLongerReceiveMessagesCallsOr =>
      'Non riceverai più messaggi, chiamate, o aggiornamenti del profilo da questo contatto.';

  @override
  String get yourId => 'Il tuo ID';

  @override
  String get yourPassphraseProtectsYourKeys =>
      'La passphrase protegge le chiavi';

  @override
  String get yourPinProtectsYourKeys => 'Il PIN protegge le chiavi';

  @override
  String get yourPrysmId => 'Il tuo Prysm ID';

  @override
  String get yourPrysmIdWillAppearOnceTorFinishes =>
      'Il tuo Prysm ID apparirà quando Tor finirà di connettersi.';

  @override
  String get chatMediaFilterAll => 'Tutto';

  @override
  String get chatMediaFilterFiles => 'File';

  @override
  String get chatMediaFilterPhotos => 'Foto';

  @override
  String get chatMediaFilterVoice => 'Voci';

  @override
  String get chooseATimeInTheFuture => 'Scegli un orario nel futuro';

  @override
  String deleteMediaFromConversation(String label, String conversation) {
    return 'Eliminare \"$label\" da $conversation? Verrà rimosso solo dal tuo dispositivo.';
  }

  @override
  String groupInviteReceivedAt(String receivedAt) {
    return 'Invito di gruppo · $receivedAt';
  }

  @override
  String scheduleSendsAt(String label) {
    return 'Invio $label';
  }

  @override
  String get sendHoldToSchedule => 'Invia. Tieni premuto per programmare';

  @override
  String get today => 'Oggi';

  @override
  String get youWillNeedThisPasswordToRestore =>
      'Ti servirà questa password per il ripristino.';

  @override
  String get openWithSystemApp => 'Apri con app di sistema';

  @override
  String get displayNameHintExample => 'es. Alice';

  @override
  String get showQrCode => 'Mostra codice QR';
}
