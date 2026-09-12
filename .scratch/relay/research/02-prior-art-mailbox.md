# Prior art: mailbox store-and-forward nei messenger che non si fidano del server

Ticket: `02-research-prior-art-mailbox.md` — Status precedente: `open` → `claimed` durante la ricerca.
Fonti primarie lette direttamente: spec SMP v20, post ufficiale Signal sealed-sender,
annuncio Briar Mailbox, XEP-0313/0352, spec Matrix client-server, docs chatmail (via secondarie
dichiarate tali dove la primaria non era raggiungibile).

---

## 1. Briar Mailbox (Tor-only, mailbox per contatto, pairing via QR)

- (a) **Cosa vede il server.** Il Mailbox vede gli ID dei contatti registrati dal proprietario
  (`contactId`, `inboxId`, `outboxId` via `POST /contacts`), gli ID dei file e le dimensioni
  dei blob depositati; i contenuti sono cifrati dal protocollo Bramble del client, quindi il
  Mailbox non legge i messaggi. Ogni Mailbox serve **un solo proprietario e i suoi contatti**:
  nessun grafo sociale globale esposto a terzi.
  ([fonte primaria: annuncio ufficiale](https://briarproject.org/news/2023-briar-mailbox-released/);
  [API.md sorgente](https://code.briarproject.org/briar/briar-mailbox/-/blob/main/API.md);
  mirror [github.com/briar/briar-mailbox](https://github.com/briar/briar-mailbox))
- (b) **Autenticazione.** Bearer token da 64 hex char (32 byte random) in header `Authorization`;
  tre principali: `SetupPrincipal` (single-use dal QR), `OwnerPrincipal` (lungo termine dopo
  `PUT /setup`), `ContactPrincipal` (per-contatto, registrato dal proprietario).
  Le cartelle non autorizzate rispondono `404` invece di `403` per non rivelare l'esistenza.
  (fonte secondaria che riporta il sorgente — dichiarata tale: pagine DeepWiki REST/API e
  auth di `briar-mailbox`)
- (c) **Antiabuso.** Non serve: il Mailbox accetta depositi **solo** da contatti registrati dal
  proprietario con token individuale; non esiste registrazione pubblica né invio anonimo.
  La revoca è la cancellazione del contatto (`DELETE /contacts/{id}`).
- (d) **Retention/quote.** Nessun TTL dichiarato pubblicamente: i messaggi restano finché il
  proprietario non li ritira/cancella; lo storage è quello del device di scorta (Android ≥ 4.3).
- (e) **Ritiro.** Pull: il client Briar, quando torna online, fetcha via Tor dal Mailbox
  (`GET /files/{folderId}`, `GET /folders` per gli outbox con novità). Chi inizia è sempre
  il proprietario (o il contatto sul proprio outbox).
- (f) **Primo contatto offline. NON gestito**: il Mailbox funziona solo fra contatti già aggiunti
  (pairing Briar in presenza via QR scambiato a vicenda, cfr.
  [manuale Briar](https://briarproject.org/manual/)). Un mittente mai incontrato non ha
  `ContactPrincipal` e non può depositare nulla.
- (g) **Errore pagato.** La critica strutturale è documentata nel dibattito sul design: scambiare
  disponibilità per fiducia nel rendezvous — il modello "tutti online via Tor" di Briar puro
  falliva su NAT/batteria, e il Mailbox sposta il problema su un secondo device sempre acceso
  (costo hardware, due superfici Tor). Inoltre resta un deposito per-contatto noto al proprietario:
  chi ruba il Mailbox mappa l'intera rubrica (ID contatti in chiaro).

## 2. SimpleX Chat — protocollo SMP (simplexmq `protocol/simplex-messaging.md`, spec v20)

- (a) **Cosa vede il server.** Solo ID effimeri di coda (`RID` destinatario, `SID` mittente,
  diversi e non correlabili senza i record del router), chiavi pubbliche effimere di coda
  (`RK`/`SK`, uniche per coda) e blob cifrati NaCl `crypto_box`. Nessuna identità persistente:
  lo stesso utente è mittente in una coda e destinatario in un'altra senza linkage visibile.
  Blocchi di trasporto a dimensione fissa (16384 byte) per uniformare il traffico.
  ([spec §SMP Model, §Simplex queue, §Transport block](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md))
- (b) **Autenticazione.** Firma Ed25519 o schema deniable (NaCl `crypto_box`) su ogni comando,
  con chiavi effimere per-coda; `NEW` può avere basic-auth opzionale lato operatore.
  ([spec §Cryptographic algorithms, §Deniable client authentication](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md))
- (c) **Antiabuso.** Chiavi per-coda + `BLOCKED` error con client notices (v16–v18); rate limit
  per identità di servizio (service certificates, v16); basic-auth su creazione code per i relay
  pubblici; i router non devono tenere log/history/snapshot in produzione.
  ([spec §Router security requirements, §Service certificates](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md))
- (d) **Retention/quote.** Messaggi conservati finché ritirati (`ACK` → cancellazione) e comunque
  per un TTL limitato: **default 21 giorni** sui relay pubblici (config `expire_messages_days`,
  sweep ogni ~2h); quota di default **128 messaggi non-acknowledgati per coda**.
  (fonte secondaria — dichiarata tale: DeepWiki simplexmq "Message storage"/"Configuration";
  la spec primaria prescrive solo "for a limited period of time", §SMP qualities)
- (e) **Ritiro.** Pull con `SUB` + `RECV`/`ACK`, oppure push via notifiche dedicate (`NKEY`/`NSUB`/
  `NMSG` con `notifierId` non correlabili agli ID di coda) verso un NTF server separato per i
  background delivery mobili. ([spec §Message delivery notifications](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md))
- (f) **Primo contatto offline — il punto chiave.** La coda nasce **non sicura** (`NEW` accetta
  `SEND` non autorizzati), l'invito viaggia out-of-band (link `smp://...?sid=...&dh=...`), poi
  scatta la **corsa a chi assicura la coda per primo**: il destinatario con `KEY`, oppure — dalla
  v9 "fast procedure" — il mittente stesso con `SKEY`, così può scrivere anche se il destinatario
  è offline. Il destinatario poi cancella `SID`/`SK` dopo il `KEY` per limitare i danni da
  compromissione futura. ([spec §SMP procedure, §Fast SMP procedure](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/simplex-messaging.md))
- (g) **Errore pagato.** La corsa alla `KEY` è il tallone documentato: chiunque conosca il `SID`
  prima della messa in sicurezza può assicurarsi la coda al posto del mittente legittimo
  (la spec lo ammette apertamente: "it's a race to secure the queue"). Mitigato ma non eliminato
  da `SKEY` del mittente.

## 3. Signal — sealed sender + server come deposito

- (a) **Cosa vede il server.** Senza sealed sender: sender + recipient + timestamp. Con sealed
  sender l'outer envelope perde il "from": il server vede **solo il destinatario** + blob opaco
  + delivery token a 96 bit; il sender certificate (numero, identity key, scadenza) viaggia
  **dentro** l'envelope cifrato con le identity key. ([post ufficiale](https://signal.org/blog/sealed-sender/))
- (b) **Autenticazione.** Doppia: sender certificate a breve scadenza prelevato dal servizio
  (anti-spoofing, verificato dal destinatario) + delivery token derivato dalla profile key del
  destinatario, di cui il mittente deve provare conoscenza (antiabuso senza autenticarsi).
  ([post ufficiale](https://signal.org/blog/sealed-sender/))
- (c) **Antiabuso.** Il token restringe il sealed sender a chi conosce la profile key (= contatti
  approvati); il blocco di un utente fa ruotare la profile key; esiste un opt-in per ricevere
  sealed sender anche da non-contatti, a rischio spam esplicito.
  ([post ufficiale](https://signal.org/blog/sealed-sender/))
- (d) **Retention/quote.** Il servizio non conserva rubrica/grafo sociale per design e recapita
  in push via websocket; i messaggi per device offline restano in coda server finché il device
  si riconnette o scade (finestra di consegna, nessun numero pubblico nella fonte primaria).
  ([post ufficiale](https://signal.org/blog/sealed-sender/) + [pagina "a record of"](https://signal.org/bigbrother/))
- (e) **Ritiro.** Push su websocket persistente per device online; pull alla riconnessione per
  gli offline; delivery receipt end-to-end (il server non attesta la lettura).
- (f) **Primo contatto offline.** Richiede numero di telefono + prekey bundle (X3DH) già
  pubblicati; sealed sender **non** apre sessioni con sconosciuti di default (serve la profile
  key, scambiata solo dopo un primo contatto normale). Il "message request" è l'ammissione
  esplicita del problema spam-da-sconosciuti.
  ([post ufficiale](https://signal.org/blog/sealed-sender/), [blog message-requests](https://signal.org/blog/message-requests/))
- (g) **Errore pagato.** Il prezzo è l'identità telefonica obbligatoria + fiducia nel server per
  certificati, profili e directory: sealed sender nasconde il mittente **al server**, ma il server
  resta l'oracolo d'identità. Critica pubblica ricorrente (es. dibattito PrivacyGuides 2025-26):
  senza numero anonimo la metadata-resistance è parziale per definizione.

## 4. XMPP — MAM (XEP-0313) + CSI (XEP-0352) + push (sintetico)

- (a) **Cosa vede il server.** Tutto il routing in chiaro: `from`/`to`/`type`/`id` di ogni stanza,
  e l'archivio MAM conserva intere stanze originali + timestamp + UID server-side.
  ([XEP-0313 §3](https://xmpp.org/extensions/xep-0313.html))
- (b) **Autenticazione.** SASL sull'account (server semi-fidato per definizione); MAM esposto sul
  bare JID dell'utente. ([XEP-0313 §3.3.1](https://xmpp.org/extensions/xep-0313.html))
- (c) **Antiabuso.** Policy server-side (roster, privacy lists XEP-0016, rate limit); niente di
  crittografico contro il server stesso.
- (d) **Retention/quote.** A discrezione del server ("MAY impose limits", solo in testa, mai buchi;
  UID mai riusati). Nessun numero nello standard: ogni operatore dichiara i suoi.
  ([XEP-0313 §3.2](https://xmpp.org/extensions/xep-0313.html))
- (e) **Ritiro.** Triplo: direct delivery su stream XML, offline store + flush alla riconnessione,
  query MAM con RSM (paginazione), CSI (`active`/`inactive`) per dire al server di sopprimere il
  traffico non essenziale su mobile, push via XEP-0357 verso FCM/APNS.
  ([XEP-0313 §4](https://xmpp.org/extensions/xep-0313.html), [XEP-0352 §3–§4](https://xmpp.org/extensions/xep-0352.html))
- (f) **Primo contatto offline.** Presence subscription + stanza offline: chiunque conosca il JID
  può far archiviare un messaggio; OMEMO richiede però il fetch dei bundle dal server (stesso
  problema prekey nostro). Lo spam da sconosciuti è il motivo di anti-spam roster-side.
- (g) **Errore pagato.** L'OTR-negoziato di XEP-0136 fu rimosso in MAM perché inapplicabile
  (il server del contatto archivia comunque); lezione: **policy anti-server non negoziabili col
  server**. ([XEP-0313 §2](https://xmpp.org/extensions/xep-0313.html))

## 5. Matrix — homeserver (spec client-server, sintetico)

- (a) **Cosa vede l'homeserver.** Quasi tutto: sender (`user_id`), `room_id`, tipo evento,
  timestamp, membership della room, grafo di federation; con E2EE megolm vede i ciphertext ma
  conserva routing + metadati completi. Sync (`GET /sync`) e `/messages` espongono lo storico
  ai client con filtri. ([spec Client-Server API](https://spec.matrix.org/latest/client-server-api/#syncing))
- (b) **Autenticazione.** `access_token` opaco per device; upload/claim delle one-time key via
  `POST /keys/upload`, `POST /keys/claim` — il server è il key-server fidato.
  ([spec Client-Server API, §End-to-End Encryption](https://spec.matrix.org/latest/client-server-api/#syncing))
- (c) **Antiabuso.** Rate limiting server-side, ACL di room, policy di federation; niente difesa
  contro un homeserver curioso.
- (d) **Retention/quote.** Storico permanente per design (event DAG replicato in federation);
  retention solo via policy locali (es. Synapse `retention` config, non standard).
- (e) **Ritiro.** Long-poll `/sync` con `since` token (iniziativa client), paginazione `/messages`,
  push via pusher/notifiche server-side.
- (f) **Primo contatto offline.** Invito in room + claim delle OTK via server anche a destinatario
  offline: funziona perché il server è l'oracolo fidato delle chiavi. È esattamente il modello
  che **non** possiamo copiare senza fidarci del Relay.
- (g) **Errore pagato.** Metadata centralizzati + key-server fidato: chi controlla l'homeserver
  mappa grafo sociale e può servire chiavi fasulle (critica nota alla verifica fingerprint/
  cross-signing come cerotto, non come rimozione della fiducia).

## 6. Delta Chat / chatmail (sintetico, numeri reali)

- (a) **Cosa vede il server.** Header email classici: From/To/Date/Subject/Message-ID + dimensioni;
  con Autocrypt il corpo è cifrato ma i metadati di routing restano in chiaro (è email).
  ([chatmail privacy](https://chatmail.email/privacy.html))
- (b) **Autenticazione.** Login IMAP/SMTP sull'account chatmail (password/device-token).
- (c) **Antiabuso.** Solo invio di messaggi cifrati consentito; niente IP logging dichiarato;
  quote rigide anti-spam. ([chatmail privacy](https://chatmail.email/privacy.html))
- (d) **Retention/quote — i numeri.** Cancellazione incondizionata dopo **20 giorni**
  (`delete_mails_after`), messaggi >200KB dopo **7 giorni**, account inattivi dopo **90 giorni**;
  alcuni operatori variano (es. chatmail.au: 30 giorni). Il client single-device cancella al
  download; il multi-device si appoggia alla retention server.
  (fonti secondarie coerenti — dichiarate tali: config `chatmail.ini` riportata da più fonti,
  [issue relay#489](https://github.com/chatmail/relay/issues/489), [chatmail.au/info](https://chatmail.au/info.html))
- (e) **Ritiro.** IMAP IDLE/pull classico + notifica push via heartbeat; iniziativa client.
- (f) **Primo contatto offline.** Email a chiunque: funziona sempre, a prezzo di zero protezione
  del destinatario — lo spam è gestito con "contact request" lato client (stesso pattern di Signal).
- (g) **Errore pagato.** Quote piene = account inutilizzabile (né invio né ricezione):
  [issue relay#489](https://github.com/chatmail/relay/issues/489) documenta utenti bloccati perché
  il multi-device non cancella abbastanza in fretta. Lezione: servono quote generose per il caso
  multi-device + cancellazione esplicita al pickup.

---

## Tabella comparativa (a)–(f)

| Sistema | (a) Vede | (b) Auth al deposito | (c) Antiabuso | (d) Retention/quote | (e) Ritiro | (f) Primo contatto offline |
|---|---|---|---|---|---|---|
| Briar Mailbox | ID contatti+file/size; contenuti cifrati | Bearer per-contatto, QR setup | Solo contatti registrati | Nessun TTL, storage del device | Pull via Tor all'online | **Non gestito** (solo contatti esistenti) |
| SimpleX SMP | ID effimeri coda + blob; zero identità | Firme effimere per-coda | BLOCKED, rate-limit, basic-auth NEW | TTL ~21gg, quota 128/coda, ACK→delete | Pull SUB/RECV/ACK + NTF push separato | Coda insicura + corsa KEY/SKEY (v9) |
| Signal | Solo destinatario (sealed) + blob | Sender cert + delivery token | Token = solo contatti | Coda finché online, no numeri pubblici | Push ws + pull a riconnessione | Richiede numero+prekey; sealed solo dopo contatto |
| XMPP MAM | from/to/type/id + stanze intere | SASL account | Roster/privacy-list server-side | A discrezione, mai buchi, UID unici | Stream + MAM/RSM + CSI + push | Subscription+offline store; spam noto |
| Matrix | sender/room/tipo/ts + membership | access_token device | Rate-limit, ACL, federation policy | Storico permanente, retention locale | Long-poll /sync + since | Invito + OTK claim via server fidato |
| chatmail | From/To/Date/size | Login IMAP | Solo-cifrato, no-IP, quote | **20gg / 7gg grandi / 90gg inattivi** | IMAP pull/IDLE | Sempre possibile (è email); contact-request vs spam |

---

## Applicabilità a Prysm — cosa importiamo, cosa scartiamo, perché

*Opinioni marcate come tali; i fatti sopra restano separati.*

1. **Modello SimpleX "ID effimeri per deposito" per i metadati del Relay.** Il Relay non deve
   vedere altro che un mailbox-ID opaco + blob + timestamp; mai sender/receiver/type in chiaro
   come oggi nel nostro envelope. Dipende da: **Threat model del relay e modello dei metadati**.
2. **Corsa KEY/SKEY come avvertimento per il primo contatto.** Se serviamo prekey/contratti per
   sconosciuti, serve una procedura di "secure rapido" stile SMP v9, altrimenti chiunque osservi
   l'advertisement può accaparrarsi il deposito. Dipende da: **Primo contatto con un peer offline**.
3. **Bearer per-deposito stile Briar per pairing utente-Relay.** Token di setup single-use
   (QR/fuori-banda) → token proprietario lungo termine → token di deposito per mittenti
   autorizzati; `404` invece di `403` sulle mailbox altrui. Dipende da: **Autenticazione e Pairing utente-Relay**.
4. **Numeri chatmail/SMP come punto di partenza per retention/quote.** TTL ~20 giorni, quota
   per-mailbox con cancellazione esplicita al pickup (lezione dell'issue #489: il multi-device
   intasa). Mai storico permanente stile Matrix/MAM integrale. Dipende da: **Retention, quote e comportamento in overflow**.
5. **Delivery-token stile sealed sender per mittenti non in whitelist.** Chi deposita senza essere
   contatto noto deve provare conoscenza di un segreto del destinatario (il contratto firmato è il
   nostro equivalente), così il Relay resta cieco sul mittente ma il destinatario verifica tutto.
   Dipende da: **Policy di accettazione: whitelist/blacklist e chi detiene la verità**.
6. **Ritiro pull-iniziato dal client, push solo come hint.** Come SMP (`SUB`/NTF separato) e
   Briar (fetch all'online): il Relay non contatta mai nessuno in uscita; `POST /sync-hint`
   resta un suggerimento best-effort. Dipende da: **Semantica di consegna e stato mostrato in UI**.

Scartiamo esplicitamente: key-server fidato stile Matrix/Signal-prekey (contraddice il nostro threat
model — vedi ticket **Prior art: prekey X3DH serviti da un'entità non fidata**); archivio permanente
federato (costo e superficie metadata); spam-management via oracolo centrale (non abbiamo un numero
di telefono né un homeserver fidato — vedi **Registrazione e anti-abuso per i Public Relay**).
