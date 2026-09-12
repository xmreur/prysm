# Confini dei moduli e scheletro dei package

Type: prototype
Status: resolved
Blocked by: 14

## Question

Qual e' il layout esatto dei moduli, e l'API pubblica minima che il client consuma?

1. **`packages/prysm_relay_protocol`**: tipi del Contract, envelope del protocollo Relay, validazione,
   errori. Zero dipendenze Flutter (deve compilare con `dart`, non con `flutter`). Quali simboli
   esporta, e quali resta libero di cambiare?
2. **`packages/prysm_relay_server`**: binario, storage, policy, integrazione Tor. Dipende **solo** dal
   package di protocollo. Come si avvia, come legge il config, come si compila
   (`dart compile exe`).
3. **Registrazione**: voce `path:` nel `pubspec.yaml` root, e cosa serve in CI
   (`.github/workflows/ci.yml` oggi fa solo `flutter pub get/analyze/test` alla radice) perche' i
   package vengano analizzati e testati senza rompere la build dell'app.
4. **Prova di indipendenza**: il server compila e passa `dart analyze` **senza** Flutter installato
   nel path di build? Il client importa solo il package di protocollo, non il server?
5. **Elenco definitivo delle seam client** toccate, confrontato con il budget della mappa (cinque piu'
   una condizionale).

## Context

- Precedenti nel repo: solo due path dependency, entrambe plugin di piattaforma
  (`packages/prysm_linux_audio`, `packages/opus_flutter_windows`). Un package Dart puro e' terreno
  nuovo: nessun hook di registrazione esiste oltre alla voce nel pubspec.
- Lo stile da seguire per i tipi immutabili e' quello di `lib/models/settings.dart`
  (`fromJson`/`toJson`/`copyWith`/`==`/`hashCode`) e per i limiti quello di
  `lib/server/inbound_limits.dart`.
- `InboundMessageRouter` e `InboundRateLimiter` sono i modelli da riusare nel server, non da copiare
  alla lettera: il server non ha Flutter, quindi niente `ValueNotifier`, niente `debugPrint`.

## Done when

- Scheletro compilabile dei due package, con `dart analyze` pulito su entrambi.
- `flutter pub get`, `flutter analyze` e `flutter test` della app continuano a funzionare.
- CI aggiornata (o deciso esplicitamente di non toccarla, con il perche').
- Elenco delle seam client confermato, o lo sforamento discusso e registrato.


## Answer

### 1. `prysm_relay_protocol`: layout e simboli esportati (letti dal codice)

Barrel `lib/prysm_relay_protocol.dart`: 9 moduli, nessun `export` oltre questi.
Simboli per file (solo dichiarazioni top-level pubbliche):

- `advertisement.dart`: `RelayEndpoint`, `RelayAdvertisement`.
- `canonical.dart`: `canonicalJson`.
- `contract.dart`: `RelayManifest`, `RelayContract`, `RelayPairRequest`.
- `errors.dart`: `RelayError`.
- `identity.dart`: `RelayIdentity`.
- `limits.dart`: `RelayLimits`.
- `messages.dart`: `RelayDepositRequest`, `RelayDepositResponse`, `RelayItem`,
  `RelayPickupRequest`, `RelayPickupResponse`, `RelayAckRequest`, `RelayAckResponse`,
  `RelayMailboxOp`, `RelayMailboxCommand`, `RelayMailboxInfo`, `RelayUsage`,
  `RelayStatusResponse`.
- `protocol.dart`: `RelayProtocol`, `RelayTenancy`, `RelayAdmission`, `RelayErrorCode`.
- `seal.dart`: `RelaySeal`.
- `signing.dart`: `RelaySigning`, `RelayFields`.

Il client si appoggia a questi (verificato con `grep` su `lib/`):
`RelayService` usa `RelayContract`, `RelayManifest`, `RelayPairRequest`, `RelayFields`,
`RelaySigning`, `RelayError`/`RelayErrorCode`, `RelayProtocol`, `RelayUsage`,
`RelayStatusResponse`, `RelayMailboxInfo`/`RelayMailboxCommand`/`RelayMailboxOp`,
`RelayEndpoint`, `RelayPickupRequest`/`RelayPickupResponse`, `RelayAckRequest`, `RelayItem`;
`RelayClient` usa `RelayManifest`, `RelayContract`, `RelayPairRequest`,
`RelayDepositRequest`/`RelayDepositResponse`, `RelayProtocol`, `RelaySigning`;
`RelayOutboundDelivery` usa `RelaySeal` (+ `RelayAdvertisement` via `PeerRelayStore`,
`RelayError`); `RelayMailboxStore`/`PeerRelayStore` e `RelayAdvertisementRefresher`
usano `RelayAdvertisement`; `RelaySettingsScreen` usa `RelayLimits`, `RelayTenancy`,
`RelayAdmission`, `RelayMailboxInfo`.
Resta libero di cambiare senza toccare il client: i membri privati (`_`) e i simboli
pubblici che il client non nomina. Congelato invece dal wire (spec normativa, non da
questo ticket): forme JSON, stringhe di firma, codici errore — li' anche un rename Dart
innocuo rompe tutto.

### 2. `prysm_relay_server`: avvio, config, compilazione (rimando, non duplicato)

Unica fonte: `packages/prysm_relay_server/README.md`. In breve: `prysm_relay init`
scrive identity + `config.json` (singolo file JSON, niente YAML by design) e il primo
token; `prysm_relay serve --config <path>` ascolta su loopback (Tor unico ingresso) con
sweeper a 60 s; `token new|list`, `status`, `fingerprint` per l'operatore; torrc e
hardening nel README. Compilazione: `dart compile exe bin/prysm_relay.dart` ->
8.017.952 byte (7,6 MiB), senza Flutter.

### 3. Registrazione: pubspec + CI (fatta)

- `pubspec.yaml` root `:36-37`: `prysm_relay_protocol: path:
  packages/prysm_relay_protocol`. L'app non dipende mai da `prysm_relay_server`.
- `.github/workflows/ci.yml`: aggiunti nello stesso job `analyze-and-test`, dopo `Test`,
  gli step `Analyze and test relay protocol`
  (`working-directory: packages/prysm_relay_protocol`) e `Analyze and test relay
  server` (`working-directory: packages/prysm_relay_server`), entrambi `dart pub get
  && dart analyze && dart test` con il `dart` del SDK Flutter gia' installato
  (`subosito/flutter-action`, nessuna seconda toolchain). Niente `--offline`: in CI la
  pub cache e' vuota e l'offline fallisce. Step esistenti, notice L3 e pin Flutter
  3.44.8 intoccati.

### 4. Prova di indipendenza (numeri della tabella fatti, verifiche mie)

- `packages/prysm_relay_protocol`: `dart analyze` pulito, 23/23 test verdi. Deps:
  `cryptography`, `crypto` (+ dev `test`). Niente Flutter.
- `packages/prysm_relay_server`: `dart analyze` pulito, 23/23 test verdi. Deps: `args`,
  `collection`, `crypto`, `cryptography`, `http`, `meta`, `path`,
  `prysm_relay_protocol` (path), `shelf`, `uuid` (+ dev `test`). Niente Flutter.
- L'app importa solo il protocollo: 6 file con
  `import 'package:prysm_relay_protocol/prysm_relay_protocol.dart'`
  (`relay_service`, `relay_client`, `relay_outbound_delivery`,
  `relay_advertisement_refresher`, `relay_store`, `relay_settings_screen`).
- `grep prysm_relay_server` su `lib; test` -> **0 match**: il server non e' mai
  importato dal client, ne' dai suoi test.

### 5. Seam client: budget 5+1 contro reale 8 nuovi + 10 modificati

Verifica: `git show --name-status 3b504cb` (commit client). Sforamento dichiarato e
motivato: la mappa non prevedeva cache dell'advertisement per contatto (colonna DB +
store), refresh in background dell'advertisement, tabella mailbox locali con migrazione
v18 -> v19, e schermata impostazioni con test widget — 4 voci fuori budget, tutte
visibili sotto.

Nuovi (8 unita': 7 file `A` da git + il blocco chiavi l10n en/it, stringhe nuove su file
esistenti):

- `lib/services/relay_service.dart` (unico oggetto relay-aware dell'app).
- `lib/transport/relay_client.dart`, `lib/transport/relay_outbound_delivery.dart`.
- `lib/services/relay_advertisement_refresher.dart`, `lib/util/relay_store.dart`.
- `lib/screens/relay_settings_screen.dart`, `test/relay_settings_screen_test.dart`.
- Chiavi Relay in `lib/l10n/app_en.arb` + `app_it.arb` (+ generati rigenerati).

Modificati (10 seam; restano fuori dal conto i 3 generati l10n, i 2 arb sopra e la tile
d'ingresso in `settings_screen.dart`):

- `lib/transport/transport_provider.dart` (`postMessageOrFallback`, relay solo su
  fallimento ritentabile), `lib/services/sync_coordinator.dart` (pickup in testa a
  `flushAllPending`, refresh advertisement in `flushPendingForPeer`).
- `lib/server/inbound_message_router.dart` (blocco `relay` firmato in `buildProfile`),
  `lib/server/PrysmServer.dart`.
- `lib/services/peer_identity_resolver.dart`, `lib/services/contact_add_service.dart`
  (cache advertisement, colonna preservata su INSERT OR REPLACE).
- `lib/util/db_helper.dart` (schema v18 -> v19: `users.relayAdvertisement`, tabella
  `relay_mailboxes`), `lib/models/settings.dart`, `lib/services/settings_service.dart`,
  `lib/app/app_composition.dart`.

### Done when: verifica punto per punto

- Scheletro compilabile + `dart analyze` pulito su entrambi: si' (tabella fatti).
- `flutter pub get/analyze/test` dell'app funzionanti: `flutter analyze` alla radice
  `No issues found!`; la voce `path:` e' l'unico hook, come previsto nel Context.
- CI aggiornata: si', punto 3 sopra (scelta: step nello stesso job, non job nuovo).
- Seam confermate, sforamento registrato: si', punto 5 sopra con motivazione.