# Relay — mappa

Label: `wayfinder:map`
Tracker: markdown locale (`.scratch/relay/`)
Ticket: `.scratch/relay/issues/NN-<slug>.md` — frontiera = file `Status: open`, senza `Blocked by` aperti

## Destination

Stato: le tre condizioni sono soddisfatte — consegna a un peer completamente spento (prova in
[relay-offline-delivery-proof.png](../../docs/relay-offline-delivery-proof.png)), esercizio dal
vivo nella sessione 2026-09-12, e documentazione in [RELAY.md](../../docs/RELAY.md),
[RELAY-USER.md](../../docs/RELAY-USER.md) e [README del
server](../../packages/prysm_relay_server/README.md) (chiusi in parallelo in questa sessione).

Un **Relay** Prysm funzionante: un server standalone in `packages/`, che accetta messaggi per un
utente offline sotto un **Contract** firmato, in versione **Private** (una sola Identity) o **Public**
(Contract aperti), e un client che lo usa attraverso non più di cinque punti di innesto.

Si arriva in fondo quando tutte e tre le cose sono vere:

1. **Funziona**: due client Prysm nel lab si scambiano messaggi senza essere mai online nello stesso
   momento, passando da un Relay.
2. **È provato dal vivo**: ogni funzionalità è stata esercitata sull'app reale con `live-app-testing`
   e i difetti trovati sono stati corretti lì, non rimandati.
3. **È documentato**: come funziona (protocollo, Contract, modello di minaccia) e come si usa (chi
   vuole gestire un Relay, chi vuole solo configurarne uno).

## Notes

**Dominio**: Prysm, messenger P2P Tor-only in Flutter/Dart. Glossario in `CONTEXT.md` (Relay, Mailbox,
Contract, Pairing, Advertisement, Pickup, e le tre parole che qui significano altro).

**Override di wayfinder**: in questo effort **l'esecuzione entra nella mappa**. I ticket decisionali
vengono prima; i ticket di build graduano dalla nebbia man mano che le decisioni cadono. Nessun ticket
di build si chiude senza prova dal vivo.

**Regola di verifica, non negoziabile**: ogni funzionalità implementata si prova con la skill
`live-app-testing` (`tool/live/prysmlab`, due container = due peer, vedi regola 17 della skill) e i bug
si correggono nella stessa sessione. Il lab non è CI: le prove ripetibili diventano test dopo.

**Skill da chiamare in ogni sessione**: `grilling` + `domain-modeling` (default per i ticket
`grilling`), `prototype` per i ticket `prototype`, `research` per i `research`, `live-app-testing` per
qualunque ticket che tocchi codice. `ponytail` quando un ticket comincia a gonfiarsi.

**Vincoli fissati in charting** (non si rinegoziano senza ridisegnare la destinazione):

- Un **solo binario** relay, policy-driven: Private = `max_tenants: 1`. Nessun fork Public/Private.
- **Dart puro**: `packages/prysm_relay_protocol` (tipi + validazione, zero Flutter) e
  `packages/prysm_relay_server` (binario). Lo schema del Contract esiste in un posto solo.
- **Solo onion**: il Relay è raggiungibile solo come hidden service.
- **Solo inbound**: il Relay riceve *per me*. Non spedisce per conto mio (vedi nebbia).
- **Il Relay si deploya fuori dall'app** (VPS, Raspberry, secondo PC) con un file di config; l'app fa
  solo il Pairing guidato. Un Relay sulla stessa macchina del client condividerebbe il suo downtime,
  e l'app ha un solo `HiddenServiceDir` in torrc (`lib/util/tor_service.dart:808-817`) e zero
  `ADD_ONION`: ospitarne un secondo vorrebbe dire toccare il ciclo di vita di Tor.
- **Advertisement = lista ordinata** già nella v1 sul wire (cambiarlo dopo sarebbe breaking), ma la v1
  usa **un solo Relay attivo**; la ridondanza è nebbia. È sicuro rimandarla: la deduplica inbound è
  già idempotente sulla PK `messages.id` con tombstone-wins (`lib/database/message_crud_dao.dart:147-190`).
- **Budget di footprint client — cinque seam, più una condizionale**:
  1. `OutboundTransport` (5 metodi) — `lib/transport/outbound_transport.dart`
  2. policy per-destinatario in `TransportProvider.postMessageOrFallback` — `lib/transport/transport_provider.dart:420`
  3. passo di Pickup in `SyncCoordinator.flushAllPending` / `onTorReconnected` — `lib/services/sync_coordinator.dart:228`
  4. campi `Settings` + `SettingsService` — `lib/models/settings.dart`, `lib/services/settings_service.dart`
  5. una schermata impostazioni + flusso di Pairing
  6. *(condizionale, solo se* **Threat model del relay e modello dei metadati** *sceglie la mailbox
     pseudonima)* pubblicazione dell'Advertisement in `buildProfile` /
     `PeerIdentityResolver` + QR payload
  Un ticket che vuole sforare si discute prima di scrivere codice.
- **Lingua**: mappa e ticket in italiano; codice, identificatori, `CONTEXT.md`, spec di protocollo e
  documentazione in inglese.
- **Deviazione dal tracker**: i findings dei ticket `research` vanno in
  `.scratch/relay/research/NN-<slug>.md`, non su un branch `research/<name>`: c'è un solo worktree e
  più agenti in parallelo non possono fare checkout concorrenti.
- **Aggiornamento della mappa**: quando più sessioni girano insieme, solo una scrive `map.md`
  (le altre chiudono il proprio ticket e lasciano il puntatore a chi coordina).

**I quattro vincoli duri del codice esistente** (ogni sessione parte da qui, sono già verificati):

1. **Il primo contatto con un peer offline oggi è impossibile, Relay o no.**
   `RatchetService.encryptBytes` fa `throw StateError('Missing prekey bundle')` senza sessione e senza
   bundle (`lib/crypto/ratchet/ratchet_service.dart:212-216`); il bundle arriva solo da un fetch live
   di `/profile` sull'hidden service del destinatario (`lib/services/peer_identity_resolver.dart:84-98`)
   e non viene **mai** persistito (`_persist` salva solo `identityJson` e `ratchetScheme`, `:113-128`).
2. **L'envelope esterno è tutto in chiaro**: `{id, senderId, receiverId, message, type, timestamp,
   groupId?, fileName?, fileSize?}` (`lib/server/inbound_message_router.dart:189-200`). Un Relay non
   può forgiare né riordinare (Ed25519 + AEAD/AAD + counter ratchet + indici sender-key), ma può
   **droppare, duplicare e ritardare** in modo indistinguibile dall'offline.
3. **I file grandi passano da un chunked transfer su WebSocket** (`fileTransferChunkMagic`,
   `wsFileTransferOps` in `lib/transport/ws_protocol.dart`), che è online-to-online per costruzione.
   Store-and-forward regge solo il POST monolitico (cap 96 MiB/msg, budget in-flight 128 MiB,
   `lib/server/inbound_limits.dart`).
4. **I gruppi fanno fan-out lato mittente**: un POST per membro, righe pending `<msgId>__<memberId>`
   (`lib/services/group_chat_service.dart:629`).

**Fatto utile**: HTTP e WebSocket convergono già su `InboundMessageRouter.handleMessage(data)`
(`lib/server/inbound_message_router.dart:182`), che accetta l'envelope **originale** e fa auth, dedup,
`pending_auth`, FTS e notifiche. Un messaggio consegnato dal Relay deve arrivare lì **byte-identico**:
il `receiverId` deve restare l'onion locale, altrimenti `_validateAddressedToLocal` (`:323-343`)
risponde 403, e il `message` non va ri-avvolto o le firme cadono.

## Decisions so far

<!-- una riga per ticket chiuso: gist + link. Le decisioni di scope prese in charting stanno nelle Notes. -->

- [Threat model del relay e modello dei metadati](issues/01-threat-model-e-modello-metadati.md):
  **mailbox pseudonima per contatto + sigillo sull'envelope**. Spec normativa in
  [relay-protocol-v1.md](../proto/relay-protocol-v1.md) §1, §2, §7. Indirizzo di consegna NON il
  Prysm ID: un **deposit address** di 32 byte casuali (hex), uno per contatto, generato dal
  proprietario e pubblicato per-richiedente in `GET /profile?requester=` (endpoint gia'
  per-richiedente, nessun nuovo messaggio per distribuirlo). L'insieme degli indirizzi registrati
  **e'** la whitelist, e revocare un contatto e' cancellare il suo indirizzo. Mittente invisibile:
  envelope sigillato *verbatim* con `relay-sealed-1` (X25519 effimero -> HKDF-SHA256 info
  `prysm-relay-seal-1` -> AES-256-GCM) verso la chiave X25519 del destinatario; al Pickup lo si
  ripassa byte-per-byte a `InboundMessageRouter.handleMessage` senza toccarne una riga. Nessuna
  firma esterna (darebbe all'operatore un oracolo per confermare "e' stato X"); autorizzazione =
  conoscenza dell'indirizzo. Sigillo sempre attivo, anche sui Private Relay, e codice in
  `packages/prysm_relay_protocol`, non in `lib/crypto`. Rischi accettati v1: lunghezza del blob,
  orari, numero di indirizzi attivi, identita' di chi ritira, drop/duplicazione/ritardo
  indistinguibili dall'offline (duplicati innocui: PK `messages.id` con tombstone-wins e gate di
  gruppo `(senderId, index)`). `blockSize` dichiarato nel Contract e nell'Advertisement dalla v1
  cosi' il padding futuro non rompe il wire; dedup del Relay su hash del blob. Il vincolo del
  codice e' confermato: `receiverId` resta l'onion locale, altrimenti `_validateAddressedToLocal`
  risponde 403. ADR: `docs/adr/0001-relay-sealed-mailbox.md`.

- [Prior art: mailbox store-and-forward nei messenger che non si fidano del server](issues/02-research-prior-art-mailbox.md):
  sei sistemi letti alle fonti. Da SimpleX SMP: indirizzi di coda opachi e distinti per mittente e
  destinatario, blocchi a dimensione fissa, TTL ~21 giorni, quota 128 messaggi non ritirati, ritiro
  con `ACK` che cancella. Da Briar Mailbox: bearer da 32 byte, setup token single-use via QR ->
  owner token, `404` invece di `403` sulle mailbox altrui, e **nessuna gestione del primo contatto**.
  Da chatmail i numeri veri di retention (20 giorni, 7 per i messaggi grandi) e la lezione della
  quota piena che uccide l'account. Da Signal il delivery token: il deposito e' ristretto a chi
  conosce un segreto del destinatario, senza che il server sappia chi e'. Scartati il key-server
  fidato stile Matrix e lo spam-management via oracolo centrale.
- [Prior art: prekey X3DH serviti da un'entita' non fidata](issues/03-research-prekey-lato-server.md):
  **si', un Relay puo' servire i bundle senza perdita di garanzie**, a cinque condizioni: firma
  dell'identita' verificata sul signed prekey corrente, nessun riuso di OTK, fallback senza OTK
  dichiarato come degrado, rate limit sul fetch piu' rifornimento, e consumo autoritativo
  riconciliato al Pickup. La spec X3DH prevede esplicitamente il caso: l'unico attacco residuo di un
  prekey server e' *rifiutare* gli OTK (§4.7), il riuso e' rilevabile dall'id dell'OTK negli initial
  message, e senza OTK si perde la forward secrecy forte, non la sessione.
- [Prior art: come un servizio Tor-only autentica gli utenti e si difende dagli abusi](issues/04-research-auth-e-antiabuso-su-onion.md):
  la difesa si divide in due. **Tor**: `HiddenServicePoWDefensesEnabled` (C Tor >= 0.4.8.1-alpha,
  dormiente a riposo), `HiddenServiceEnableIntroDoSDefense`, `HiddenServiceMaxStreams` +
  `CloseCircuit`, `HiddenServiceExportCircuitID` per vedere i circuiti, client authorization v3 come
  hardening dei Private Relay (revoca solo con restart di tor). **Applicazione**: contratto firmato,
  capability token, quote e TTL — Tor non li fa. Non riproporre mai: qualunque difesa su IP,
  geolocalizzazione o reputazione (l'app vede solo localhost), CAPTCHA di terze parti, TLS con CA,
  PoW come autenticazione, client-auth come rate limiter.
- [Indirizzamento della Mailbox e Advertisement del Relay](issues/05-indirizzamento-e-advertisement.md):
  Spec §2. Forma `relay: {v, issuedAt, expiresAt, relays:[{onion, deposit, maxItemBytes,
  blockSize}], sig}`, firmato Ed25519 su `prysm-relay-advert-1|<ownerFpr>|...`: in cache resta
  **verificabile offline**, cioe' proprio quando il proprietario e' irraggiungibile. **Lista
  ordinata dalla v1** (cambiarla dopo sarebbe breaking) ma un solo Relay attivo, sicuro da
  rimandare perche' la dedup inbound e' idempotente. Pubblicazione in `GET /profile?requester=`
  per-contatto, erede della redazione di `buildProfile`; il QR **non** cambia
  (`prysm:v2:onion:fingerprint` resta, l'Advertisement si impara al primo fetch del profilo, che
  avviene comunque perche' aggiungere un contatto richiede il peer online). Cache lato mittente in
  `users.relayAdvertisement` (TEXT JSON), migrazione v18 -> v19, scritta da
  `PeerIdentityResolver`. Scaduto o assente -> nessuna consegna via Relay; Relay muto o errore non
  ritentabile -> coda locale per la diretta. Ritenta piu' tardi solo su `mailbox_full`,
  `tenant_full`, `rate_limited`, `internal`, `stale_request`.
- [Autenticazione e Pairing utente<->Relay](issues/06-auth-e-pairing-utente-relay.md): spec §3.1,
  §3.2, §3.9, §4. **Pairing** stile Briar Mailbox: setup token da 32 byte hex, monouso, con
  scadenza, generato via CLI; `POST /relay/pair` con identita', onion, opzioni e firma su
  `prysm-relay-pair-1|<relayFpr>|<ownerFpr>|<token>|<ts>`; il Relay clampa le opzioni e restituisce
  il **Contract firmato**. Prima del pairing l'app mostra `GET /relay/manifest` firmato: l'utente
  vede *chi* accetta e *cosa* promette. Auth ricorrente senza token di sessione: tre header
  (`X-Prysm-Owner`, `X-Prysm-Timestamp`, `X-Prysm-Signature`), firma Ed25519 su
  `prysm-relay-auth-1|<relayFpr>|<ownerFpr>|<METHOD> <path>|<ts>|<sha256(body)>`, skew ±300 s e
  cache dei digest per 600 s contro il replay (stesso schema di `PeerProof`, riusato). Prova di
  possesso dell'onion **non** richiesta in v1, rischio accettato: aprire una Mailbox per l'onion di
  un altro non da' accesso a nulla e costa solo quota. Revoca = `POST /relay/unpair`, cancella
  tenant, mailbox e item (irreversibile); rotazione indirizzo = put del nuovo + delete del vecchio;
  chiavi perse = nuovo pairing, vecchia Mailbox scade per TTL; cambio onion = nuovo Advertisement.
  Client authorization v3 di Tor fuori dalla v1, resta hardening consigliato in documentazione.
- [Primo contatto con un peer offline](issues/07-primo-contatto-offline.md): **il Relay non serve
  prekey nella v1**, limite scritto in chiaro in documentazione utente (spec §8). La ricerca dice
  che servire bundle si *puo'* fare, ma solo con cinque condizioni simultanee (firma verificata sul
  signed prekey, nessun riuso di OTK, fallback senza OTK dichiarato, rate limit + rifornimento,
  consumo autoritativo riconciliato al Pickup): un endpoint family in piu' e uno stato fuori dal
  dispositivo, troppo per la v1 e ortogonale al problema dei Relay. Il limite e' accettabile perche'
  aggiungere un contatto **richiede gia' entrambi online** (stesso fetch di `/profile` che porta
  l'Advertisement): *"scambiatevi il contatto una volta online, da quel momento il Relay copre
  tutto"* (come Briar Mailbox, che il primo contatto non lo gestisce affatto). In nebbia la forma
  futura: snapshot firmato + pool OTK con consumo marcato, riconciliato al Pickup, degrado a
  signed-prekey-only.
- [Policy di accettazione: whitelist/blacklist e chi detiene la verita'](issues/08-policy-accettazione-whitelist-blacklist.md):
  Spec §2, §3.3, §3.4. Chiave del filtro = **deposit address**, non il mittente: il Relay non vede
  mai un'identita' di mittente, e la whitelist esiste **senza** che conosca la rubrica (`label`
  opaco, omissibile). Modalita' v1: whitelist implicita (esistenza dell'indirizzo) + `disable` per
  sospendere senza perdere gli item + `delete` per revocare + tetti per indirizzo (`maxItems`,
  `maxBytes`); nessuna blacklist, in questo modello non ha senso. Nessuna sincronizzazione di
  liste: `BlockService` e `refuseUnknownSenders` restano la verita' lato client e valgono **dopo**
  il Pickup; invariante: **il Relay non puo' allargare cio' che il client rifiuta** (bloccare un
  contatto in app deve `delete` il suo indirizzo). Mittente rifiutato: `404 mailbox_unknown`,
  identica per "mai esistito" e "revocato" (stesso principio dell'ack-and-drop e del 404 di Briar).
  Sospensione = `disable` di tutti gli indirizzi; in nebbia orari, tetti piu' fini, "sotto N byte".
- [Retention, quote e comportamento in overflow](issues/09-retention-quote-overflow.md): spec §3.1,
  §3.4, §4, §5. Limiti nel Contract, negoziabili entro il manifest: `maxItemBytes`,
  `maxMailboxItems`, `maxTenantBytes`, `itemTtlSeconds`, `maxMailboxes`. Default: TTL **20 giorni**
  (chatmail, ~21 SimpleX), `maxMailboxItems` 256 (SimpleX 128 per coda), `maxItemBytes` 1 MiB su
  Public / 8 MiB su Private, `maxTenantBytes` 64 MiB su Public / 256 MiB su Private, `maxMailboxes`
  512. Overflow = **`reject`** unica policy v1: `mailbox_full` / `tenant_full` (507,
  **ritentabile**), mai scarto del piu' vecchio — il nuovo perso e' visibile al mittente che lo
  tiene in coda (50 ritentativi con backoff ~2/4/8/16/30 s), il vecchio perso non lo vedrebbe
  nessuno (lezione di chatmail). Cancellazione **dopo ack esplicito** (`POST /relay/ack`): morire a
  meta' Pickup non perde nulla, al costo di un round-trip e un id per item. L'utente vede item,
  byte, numero di mailbox e scadenza piu' vicina via `POST /relay/status` (dato aggiornato al
  Pickup, unico momento di dialogo). Sweeper del server ogni 60 s su scaduti e token.
- [Allegati e messaggi grandi attraverso il Relay](issues/10-allegati-e-messaggi-grandi.md):
  **cap contrattuale**, nessuna API blob in v1 (spec §3.4, §8). `maxItemBytes` 1 MiB Public / 8 MiB
  Private: testo, reazioni, ricevute, modifiche, timer, controllo gruppo, immagini piccole. Sopra il
  cap il mittente **non** usa il Relay: coda locale per la diretta, e il Relay risponde `413
  item_too_large` (non ritentabile). Il chunked transfer su WebSocket resta direct-only fra vivi,
  senza degrado automatico al POST monolitico: oltre il cap si aspetta il peer. `fileName` e
  `fileSize` viaggiano **dentro il sigillo**, il Relay vede solo la lunghezza del blob. In nebbia
  la forma futura: `POST /relay/blob/init|chunk|commit` + riferimento in envelope sigillato, con
  garbage collection dei parziali.
- [Gruppi: fan-out e cosa vede il Relay](issues/11-gruppi-fanout.md): **fan-out lato mittente**,
  Relay ignaro dei gruppi — un deposito per membro, sul Relay *di quel membro*, all'indirizzo che
  quel membro ha pubblicato (spec §1, §8; la forma dati esiste: pending `<msgId>__<memberId>` e
  `_GroupChatTransportPostman`). `groupId` **dentro il sigillo**: il Relay correla i membri solo
  per co-occorrenza temporale (rischio accettato). Controllo (`control-wrap-2`: inviti, epoche,
  rimozioni) stesso percorso, **nessuna scadenza** v1: la validita' e' crittografica non temporale,
  toccarla e' fuori scope; unico limite il TTL di 20 giorni. History Backfill **non** attraversa il
  Relay: le sue righe pendenti si scartano all'avvio (`lib/services/group_service.dart:1083-1093`),
  relayarle contraddirebbe una decisione presa. Membri senza Relay: coda locale come oggi, nessun
  "consegnato N su M" (sforerebbe il budget UI; in nebbia con la delivery receipt). Bonus atteso da
  verificare dal vivo: non-contatti che oggi non formano il link WS (134 s nel lab) diventano un
  deposito normale.
- [Semantica di consegna e stato mostrato in UI](issues/12-semantica-consegna-e-stato-ui.md):
  **nessuno stato nuovo in v1** (spec §6). Accettato dal Relay = `sent`, come il 2xx di oggi
  (`ChatService._markAsSent`): un valore in piu' in `messages.status` toccherebbe query, viste,
  mappature e stringhe in due lingue, sforamento per un guadagno non chiesto. Ricevuta di deposito
  `{status:'stored', itemId, expiresAt}` **non firmata**: la firma servirebbe a provare a terzi
  l'accettazione e non c'e' consumatore; il client non la persiste, solo log di diagnosi. Delivery
  receipt ("ha ritirato") **fuori v1 per privacy, non per costo**: rivelerebbe quando il
  destinatario torna online, cosa che Prysm oggi non rivela (se entrera', interruttore proprio, non
  `sendReadReceipts`). Mai ritirato: il mittente non vede nulla di diverso, scade il TTL di 20
  giorni. In nebbia: stato "in deposito", eta' del deposito, receipt di ritiro.
- [Registrazione e anti-abuso per i Public Relay](issues/13-antiabuso-relay-pubblici.md): spec
  §3.1, §3.2, §3.9, §5. Ammissione v1 **`invite`** di default anche sui Public (token monouso con
  scadenza dall'operatore); `open` solo abilitata a mano e dichiarata nel manifest; `closed`
  blocca i nuovi Contract. Nessun PoW applicativo: prova effort, non identita'; la PoW che serve e'
  quella di **Tor** (`HiddenServicePoWDefensesEnabled`, `EnableIntroDoSDefense`, `MaxStreams` +
  `CloseCircuit`: da runbook, non da implementare). Difese applicative: quote per tenant/mailbox +
  rate limit a finestra fissa — 60 depositi/min per indirizzo, 30 pickup/min per tenant, 10
  pair/ora — sul modello di `lib/server/inbound_rate_limiter.dart`, con chiave l'identita'
  applicativa o il deposit address, **mai l'IP** (l'app vede solo localhost). Sanzioni: `429
  rate_limited` e `507 *_full` (ritentabili), `403 admission_closed` / `bad_token`; nessun ban
  permanente, unica sanzione = revoca del Contract. **Manifest firmato** come termini pubblici visti
  **prima** del Pairing. Log default `counters`: mai un deposit address oltre i primi 6 hex, mai un
  payload, mai un onion di proprietario (`debug` esiste ma avvisa all'avvio).
- [Il Contract: schema, negoziazione, firme, revoca, versioning](issues/14-contratto-schema-e-negoziazione.md):
  Artefatto: **[relay-protocol-v1.md](../proto/relay-protocol-v1.md)** + tipi Dart in
  `packages/prysm_relay_protocol` con round-trip JSON e validazione. Contract: `protocol, version,
  relayFingerprint, relayOnion, ownerFingerprint, ownerOnion, tenancy,
  limits{maxItemBytes, maxMailboxItems, maxTenantBytes, itemTtlSeconds, maxMailboxes, blockSize},
  overflow, issuedAt, expiresAt, sig` — firma del Relay su
  `prysm-relay-contract-1|<JSON canonico senza sig, chiavi ordinate, nessuno spazio>`. Tre atti:
  manifest firmato -> richiesta firmata con opzioni scelte -> Contract **clampato** ai limiti; il
  client rifiuta se `relayFingerprint` non corrisponde al manifest del Pairing. Ciclo di vita:
  `expiresAt` nullable (Private senza scadenza), rinnovo = nuovo pair con token fresco idempotente
  (`version` incrementa), revoca = `unpair` che cancella tutto. Versioning: `protocol` id esatto
  (`prysm-relay/1`), rifiuto se diverso; campi `limits` sconosciuti **ignorati**, `protocol`
  sconosciuto = `bad_request`; nessuna negoziazione. Errori tipizzati con ritentabilita' in §3.9;
  ogni campo tracciabile al ticket che lo ha deciso, nessun campo orfano.

- [Lab a tre nodi per il live app testing del Relay](issues/16-lab-tre-nodi.md): il lab regge tre nodi
  su Tor reale. Due client (`prysm-lab`, `prysm-lab-b` via override env) + un terzo container con Tor
  e hidden service: `curl --socks5-hostname` verso l'onion del terzo nodo riesce **da entrambi** i
  client (4 s da A, 8 s da B; prima fetch 112 s = propagazione del descriptor, non un bug).
  **Baseline misurata**: consegna diretta A->B 4-13 s a link caldo; drain di un peer spento **3/3
  messaggi resi entro 9 s** dalla HomeScreen (conferma gli 8-11 s della skill). Runbook riproducibile
  in [lab.md](lab.md), con 13 trabocchetti pagati — il piu' importante e' il **numero 10**: l'albero
  dei widget puo' essere *stale* perche' il pipeline dei frame si blocca, e va forzato con
  `scheduleForcedFrame()` prima di concludere che la UI non si aggiorna.
- [Bonifica dei placeholder Relay morti nel client](issues/17-bonifica-placeholder-relay.md): terreno
  pulito, **108 righe rimosse in 8 file, zero aggiunte**. Eliminati i tre campi persistiti e mai letti
  (`enableRelay`, `personalRelayAddress`, `aggressiveRetry`), lo switch `kDebugMode` che non
  persisteva nulla, il blocco commentato che non avrebbe compilato, e le due chiavi l10n
  (`enableRelayServer`, `comingSoonNotWorking`) rigenerando i file con `flutter gen-l10n`. Nessuna
  migrazione necessaria: `Settings.fromJson` legge ogni chiave con `?? default` e ignora quelle che
  non conosce. `flutter analyze` pulito, 4 file di test settings verdi (+16), History Backfill
  intatto. **Provato dal vivo**: `SettingsScreen` rende (60+ stringhe), `Enable relay server` e
  `Coming soon (not working)` contano **0**, `Refresh Tor Circuit` conta 1, nessun testo "relay"
  nell'albero — e il lab gira un build debug, dove quello switch *sarebbe stato* visibile. I nomi
  definitivi dei campi settings li decidera' il ticket sull'indirizzamento.

## Not yet specified

<!-- nebbia in scope: si vede che arriva, non è ancora abbastanza nitida per un ticket -->

- **Suite di prove dal vivo**: la policy di Pickup (`delivered`/`dropped`/`keep`) e la refresh
  all'apertura della schermata Relay sono ora difese da test
  (`test/relay_pickup_policy_test.dart`, `test/relay_settings_screen_test.dart`). Resta da
  decidere quali altri scenari già esercitati dal vivo si promuovono a test automatico (quota
  piena, whitelist che rifiuta, gruppo con membri misti).
- **Spooler outbound** per destinatari che non hanno alcun Relay.
- **Ridondanza multi-relay e failover.**
- **Relay co-ospitato** su un desktop sempre acceso.
- **Compatibilità wire**: cosa fa un client vecchio se l'envelope cambia, e se serve una migrazione.
- **Padding e pickup civetta**: `blockSize` dichiarato a 0 dalla v1 per accenderlo senza rompere il
  wire; pickup civetta come mitigazione della correlazione temporale.
- **API blob per gli allegati**: `POST /relay/blob/init|chunk|commit` + riferimento dentro
  l'envelope sigillato, con garbage collection degli upload parziali.
- **Prekey serviti dal Relay**: snapshot di profilo firmato + pool OTK caricati dall'utente, consumo
  marcato dal Relay e riconciliato al Pickup, degrado a signed-prekey-only a pool vuoto.
- **Delivery receipt**: dire al mittente quando il destinatario ritira, con interruttore privacy
  proprio (oggi Prysm non rivela quando un peer torna online).

## Out of scope

<!-- oltre la destinazione: chiuso, non gradua mai -->

- **Relay a pagamento o con incentivi economici** — mai.
- **Relay come trasporto per le chiamate audio** — real-time incompatibile con store-and-forward.
- **Relay in clearnet, non-Tor** — mai.
- **Federazione Relay↔Relay**: il fan-out lato mittente verso il Relay del destinatario copre già il
  caso d'uso; la federazione aggiungerebbe solo hop di ciphertext fra terzi.
- **Sincronizzazione multi-dispositivo**: Prysm ha un solo dispositivo attivo, esiste solo il
  trasferimento same-account (`backup v3`, commit `3eb3b36`). Effort separato.
