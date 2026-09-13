# Threat model del relay e modello dei metadati

Type: grilling
Status: resolved
Blocked by: 02 (resolved), 04 (resolved)

## Question

Quale modello di fiducia adottiamo verso un Relay, e di conseguenza **cosa deve vedere** per
funzionare? Tre sotto-decisioni, da chiudere insieme perche' si tengono per mano:

1. **Indirizzo di consegna**: resta il Prysm ID del destinatario nell'envelope invariato, oppure
   diventa un token di Mailbox opaco derivato dal Contract (e allora chi lo deriva, il mittente o il
   destinatario, e come lo impara il mittente)?
2. **Mittente**: `senderId` resta in chiaro nell'envelope esterno o migra dentro il ciphertext?
3. **Rischi accettati**: cosa assumiamo che un operatore possa fare (drop, duplicazione, ritardo
   arbitrario, correlazione per orario e dimensione, grafo sociale) e quali di questi accettiamo
   invece di mitigare, separando Private Relay da Public Relay.

## Context

- L'envelope esterno e' interamente in chiaro: `{id, senderId, receiverId, message, type, timestamp,
  groupId?, fileName?, fileSize?}` (`lib/server/inbound_message_router.dart:189-200`).
- Il Relay **non puo' forgiare ne' riordinare** (Ed25519 sulle firme, AEAD con AAD su header e
  counter, indici sender-key), ma **puo' droppare, duplicare, ritardare**. La duplicazione e' innocua
  sul lato client: `messages.id` e' PK con tombstone-wins (`lib/database/message_crud_dao.dart:147-190`),
  i gruppi hanno il gate `(senderId, index)` (`lib/util/group_sender_index_store.dart`).
- Vincolo dirimente per l'opzione "token opaco": `_validateAddressedToLocal`
  (`lib/server/inbound_message_router.dart:323-343`) rifiuta con 403 qualunque envelope il cui
  `receiverId` non sia l'onion locale. Quindi o l'envelope conserva il `receiverId` (e il token vive
  **fuori** dall'envelope, come indirizzo di deposito), oppure qualcuno lo traduce prima
  dell'ingresso, e quel qualcuno e' codice client.
- Il gruppo verifica `senderId == senderId del trasporto` (`lib/crypto/group_crypto.dart`), e le
  `PeerProof` firmano `contesto|sender|receiver|timestampMs` (`lib/crypto/peer_proof.dart`): spostare
  il mittente dentro il ciphertext ha conseguenze oltre la privacy.
- Le prove `dm-signed-*` non hanno counter: duplicati e ritardi non sono rilevabili al livello crypto
  per i messaggi diretti legacy; `ratchet-2/3` rifiuta il replay e tollera buchi fino a 256.

## Done when

- Per ogni campo dell'envelope e' scritto se il Relay lo vede, e perche'.
- E' deciso se l'envelope cambia: se si', quali seam client si toccano (e se si attiva la sesta seam
  condizionale della mappa).
- I rischi accettati sono elencati esplicitamente, distinti fra Private e Public Relay.
- Le mitigazioni rimandate finiscono in **Not yet specified**, non nel silenzio.
- Se la scelta e' costosa da invertire, si registra un ADR in `docs/adr/`.

## Answer

Deciso: **mailbox pseudonima per contatto + sigillo sull'envelope**. Spec normativa in
[`relay-protocol-v1.md`](../proto/relay-protocol-v1.md) §1, §2, §7.

1. **Indirizzo di consegna**: NON il Prysm ID. Un **deposit address** di 32 byte casuali (hex),
   **uno per contatto**, generato dal proprietario e pubblicato per-richiedente in
   `GET /profile?requester=` — endpoint che e' **gia'** per-richiedente
   (`lib/server/inbound_message_router.dart:99-126`), quindi non serve nessun nuovo tipo di
   messaggio per distribuirlo. L'insieme degli indirizzi registrati **e'** la whitelist, e revocare
   un contatto e' cancellare il suo indirizzo: il Relay filtra senza sapere nulla della rubrica.
2. **Mittente**: invisibile al Relay. L'envelope originale viene sigillato *verbatim* con
   `relay-sealed-1` (X25519 effimero -> HKDF-SHA256 info `prysm-relay-seal-1` -> AES-256-GCM) verso
   la chiave X25519 del destinatario. Al Pickup si riottiene l'envelope byte-per-byte e lo si passa a
   `InboundMessageRouter.handleMessage`: `receiverId` e' gia' l'onion locale (nessun 403 da
   `_validateAddressedToLocal`), le firme interne sono intatte, la pipeline inbound non cambia di
   una riga. Il sigillo vive in `packages/prysm_relay_protocol`, **non** in `lib/crypto`.
3. **Nessuna firma esterna**: l'autenticita' e' del layer interno; una firma esterna darebbe
   all'operatore un oracolo per testare chiavi pubbliche candidate e confermare "e' stato X".
   L'autorizzazione a depositare e' la conoscenza dell'indirizzo (pattern delivery-token di Signal).
   Domain separation obbligatoria: l'info HKDF differisce da `hkdfInfoDhAead`, quindi un blob
   sigillato non e' riproducibile nel percorso DM 1:1.
4. **Un solo percorso di codice**: il sigillo e' sempre attivo, anche sui Private Relay. Due percorsi
   = due modelli di minaccia; e "il relay e' mio" non e' una proprieta' di sicurezza (la macchina si
   noleggia, si sequestra, si ruba).
5. **Rischi accettati nella v1**: lunghezza del blob, orario di arrivo, numero di indirizzi attivi
   (approssima il numero di contatti), identita' di chi ritira (il Contract la dichiara), e
   drop/duplicazione/ritardo indistinguibili dall'offline. Duplicati innocui: `messages.id` e' PK
   con tombstone-wins (`lib/database/message_crud_dao.dart:147-190`) e i gruppi hanno il gate
   `(senderId, index)`. Mitigazioni rimandate in nebbia (padding, Pickup civetta), ma `blockSize` e'
   **dichiarato nel Contract e nell'Advertisement dalla v1**, cosi' accendere il padding non rompe
   il wire.
6. **`id` del messaggio dentro il sigillo**: la dedup e' gia' idempotente sul client; al Relay
   servirebbe solo a risparmiare disco, e puo' farlo sull'hash del blob.

ADR: `docs/adr/0001-relay-sealed-mailbox.md` (formato del wire = costoso da invertire).
