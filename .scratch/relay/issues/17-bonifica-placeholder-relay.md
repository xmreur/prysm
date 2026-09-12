# Bonifica dei placeholder Relay morti nel client

Type: task
Status: resolved

## Question

Il terreno va pulito prima di costruirci sopra: oggi in `lib/` ci sono resti di un Relay che non
esiste, e uno di questi non compilerebbe nemmeno se qualcuno lo riattivasse.

Da fare:

1. Rimuovere le tile **commentate** "Relay Address" e "Aggressive Retry"
   (`lib/screens/settings_screen.dart:984-1000`): referenziano `_showRelayAddressDialog`,
   `_relayAddress`, `_aggressiveRetry`, `_onAggressiveRetryToggle`, che **non esistono**.
2. Rimuovere lo switch `kDebugMode` con sottotitolo `comingSoonNotWorking` (`:1217-1224`), che
   `onChanged` ritorna `true` senza persistere nulla, e lo stato locale `_enableRelay` (`:92`, caricato
   a `:134`) se resta orfano.
3. Decidere il destino dei tre campi **persistiti e non letti da nessuno**: `enableRelay`,
   `personalRelayAddress`, `aggressiveRetry` (`lib/models/settings.dart:19-21`,
   `lib/services/settings_service.dart:65-68`, `:217-230`) — tenerli come base per la v1, rinominarli
   coerentemente col glossario, o rimuoverli con migrazione del blob `app_settings` in
   SharedPreferences. Registrare la decisione nel ticket: e' l'unica parte decisionale, ed e' locale.
4. Le stringhe l10n `enableRelayServer` e `comingSoonNotWorking` (`lib/l10n/app_en.arb:818,966`,
   `app_it.arb:437,585`): tenere o rimuovere in coerenza con il punto 2.

Nessuna funzionalita' nuova: questo ticket **toglie**, non aggiunge.

## Context

- La ricetta per una nuova area di impostazioni (quando servira') e', per precedente reale
  (`refuseUnknownSenders`, `groupInviteMode`): campo nel modello -> getter/setter nel service -> UI
  nella schermata -> chiavi ARB in `app_en.arb` e `app_it.arb` + `flutter gen-l10n` -> test di
  round-trip JSON e persistenza.
- Non confondere questi resti con il significato **non** Relay della parola: `groupHistoryRelayType`
  (`lib/constants/group_constants.dart:10`) e `discardPendingHistoryRelay`
  (`lib/services/group_service.dart:1084`) sono History Backfill e non si toccano — la stringa e' sul
  wire.

## Done when

- `flutter analyze` pulito e nessun riferimento morto a relay in `lib/screens/settings_screen.dart`.
- I test di settings esistenti passano; se i campi cambiano, il test di round-trip e' aggiornato.
- Prova dal vivo: nel lab, `prysmlab tap "Settings"` apre la schermata e `prysmlab screen` mostra che
  rende ancora (la schermata impostazioni e' un ramo di `HomeScreen`, non una route: `pop` non
  funziona la', regola 5 della skill).
- Decisione sui tre campi scritta nella sezione `## Answer` del ticket.

## Answer

### Decisione sui tre campi: ELIMINATI tutti e tre
`enableRelay`, `personalRelayAddress`, `aggressiveRetry` sono stati rimossi da
`lib/models/settings.dart`, `lib/services/settings_service.dart` (getter, setter, righe di
`printSettings`) e, per `enableRelay`, dallo stato locale della schermata impostazioni.
Motivi: (1) sono morti — nessun lettore/scrittore reale (vedi evidenza sotto), gli unici setter
esistenti non erano mai chiamati; (2) i nomi giusti (indirizzo? token? policy?) li decidera' il
ticket sull'indirizzamento, tenere questi nomi oggi significherebbe ancorare la v1 a placeholder;
(3) la rimozione non richiede codice di migrazione (vedi prova `fromJson` sotto).

### Evidenza di verifica (prima di rimuovere — la premessa del ticket era corretta)
- (a) Tile commentate non compilanti: `grep` su `lib/screens/settings_screen.dart` mostrava
  `_showRelayAddressDialog` (`:989`), `_relayAddress` (`:990`), `_aggressiveRetry` (`:998`),
  `_onAggressiveRetryToggle` (`:999`) **solo** dentro il blocco commentato `:984-1000`, mai come
  definizioni. Nota: nessuno strumento `lsp` disponibile in questo ambiente; la verifica e'
  ottenuta con `grep` repo-wide (`lib; test; tool; packages`), che per riferimenti statici Dart e'
  esaustivo.
- (b) Switch `kDebugMode` (`:1217-1224`): `onChanged` era `(bool value) { return true; }` — nessun
  `save()`/`setEnableRelay`, nulla persistito.
- (c) Nessun lettore oltre schermata/test: `grep` per
  `enableRelay|personalRelayAddress|aggressiveRetry` su `lib; test; tool; packages` trovava match
  solo in `settings.dart`, `settings_service.dart`, `settings_screen.dart:92,134,1221` e nelle ARB.
  In `test/` **zero** match: nessun test di settings li nominava, quindi nessun test da aggiornare.
  `personalRelayAddress` e `aggressiveRetry` non erano letti nemmeno dalla schermata (solo
  `enableRelay` a `:134`).
- l10n: `comingSoonNotWorking` usata solo in `settings_screen.dart:1219`,
  `enableRelayServer` solo in `:1218` (piu' ARB + generati). Nessun'altra feature "in arrivo" le
  riusava: entrambe rimosse.

### Prova `fromJson` (nessuna migrazione necessaria)
`Settings.fromJson` (`lib/models/settings.dart:111-145`, ora rinumerato) legge ogni chiave con
`json['chiave'] ?? default` e ignora le chiavi sconosciute: un blob `app_settings` esistente che
contiene ancora `enableRelay`/`personalRelayAddress`/`aggressiveRetry` viene parsato senza errori e
i valori morti vengono semplicemente dimenticati al primo `save()` (che riscrive il blob da
`toJson`, ormai senza quelle chiavi). Nessun dato utile perso (i campi non erano mai scritti da
alcuna UI), nessun `throw` su chiavi mancanti (tutti i campi hanno `??` default) — il `load()` ha
comunque un try/catch con fallback ai default.

### Diff riassunto (108 righe rimosse, 0 aggiunte — `git diff --stat`)
- `lib/screens/settings_screen.dart` (-29): blocco commentato `:984-1000`, campo `_enableRelay`
  (`:92`), caricamento a `:134`, switch di debug + divider (`:1217-1226`, ex-numerazione). La
  sezione debug resta con le altre tile (`previewUpdateDialog`, `testUpdateFlow`).
- `lib/models/settings.dart` (-27): i 3 campi, params costruttore, voci `toJson`/`fromJson`,
  params e assegnazioni `copyWith`, frammento `toString`, confronti `==`, termini `hashCode`.
- `lib/services/settings_service.dart` (-24): 3 getter, 3 setter, 3 righe di log in `printSettings`.
- `lib/l10n/app_en.arb`, `app_it.arb` (-2 ciascuna): chiavi `enableRelayServer`,
  `comingSoonNotWorking`; rigenerati `app_localizations*.dart` con `flutter gen-l10n`
  (exit 0, usa `l10n.yaml`; solo le 12+6+6 righe dei due getter spariscono).
- History Backfill intatto: `git diff -- lib/ | grep groupHistoryRelayType|discardPendingHistoryRelay`
  vuoto (exit 1 = nessun match); nessun file di gruppi nel diff.

### Output comandi
- `flutter analyze` -> `No issues found! (ran in 3.3s)` — pulito, nessun warning pre-esistente da
  confrontare.
- `grep -n relay|Relay lib/screens/settings_screen.dart` -> `No matches found` (entrambi i case).
- `flutter test test/settings_migration_test.dart test/group_settings_screen_test.dart
  test/locale_settings_test.dart test/group_invite_mode_settings_test.dart` ->
  `All tests passed!` (+16, in ~2s). Eseguiti tutti e 4 i file di test settings esistenti (nessuno
  nominava i campi rimossi, quindi nessuna modifica ai test).
- Suite completa NON eseguita (vietata dal contratto del task).

### Prova dal vivo — eseguita da Main (2026-09-12, lab Linux)

Lab ricostruito (`build-image` dopo il `down --purge` di LabThreeNodes), `up` 35 s, identita' del
lab creata con PIN `223311`, HomeScreen raggiunta, poi:

```
tool/live/prysmlab tap-widget --type Semantics --contains "Settings"
  -> TAPPED n=2 x=1248.0 y=35.0 w=48.0 h=48.0 hit=yes
tool/live/prysmlab screen
  -> "screens": ["HomeScreen", "PrysmPage", "SettingsScreen"]
     60+ stringhe rese: Appearance / Language / Light..Orange Mode / Font / Text size /
     Message bubble rounding / Privacy / Unlock method / Change passcode / Blocked contacts /
     Invite requests / Advanced Privacy / Network / General / Data ...
tool/live/prysmlab count 'Enable relay server'     -> 0
tool/live/prysmlab count 'Coming soon (not working)' -> 0
tool/live/prysmlab count 'Refresh Tor Circuit'     -> 1
tool/live/prysmlab screen | grep -i relay          -> nessuna occorrenza
```

Il lab gira un build **debug**, quindi prima della bonifica lo switch `kDebugMode` "Enable relay
server" **sarebbe stato visibile**: la sua assenza e' una differenza osservabile, non un'inferenza.
La sezione **Network** rende ancora la sua unica tile superstite (`Refresh Tor Circuit`), quindi la
rimozione non ha svuotato la sezione ne' rotto il layout. Teardown eseguita (`down --purge`:
container, volume, staging e immagine rimossi; nessun `prysm-lab*` residuo).

Nota: il punto 5 della skill `live-app-testing` e' confermato — `SettingsScreen` e' un ramo del
build di `HomeScreen` (`lib/screens/home/home_screen.dart:2343-2348`), non una route, e il suo
bottone non ha testo: si raggiunge solo via `Semantics(label:)` (`:1403-1407`), non con
`tap "Settings"` (che risponde `NOTFOUND n=0`).
