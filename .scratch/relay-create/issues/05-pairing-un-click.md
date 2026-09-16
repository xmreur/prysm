# Pairing a un click dal provisioning

Type: prototype
Status: resolved
Blocked by: 04

## Question

Alzare la fedeltà della discussione con un artefatto concreto: oggi l'accoppiamento è copia-incolla manuale di tre valori (onion + fingerprint + token) più trappola del primo tentativo freddo (39,8 s contro budget 30 s). Come diventa "un click"?

Da prototipare (HITL — serve reagire a qualcosa di concreto, non a un'opinione):

1. Formato del bundle di pairing: QR e/o deep-link con onion + fingerprint + token (+ TTL?) — cosa contiene, come è codificato, chi lo genera (output del provisioning) e dove vive il segreto nel frattempo.
2. Flusso app minimo reagibile: mock della schermata Relay che ingerisce il bundle, mostra manifest + fingerprint da confrontare fuori banda, e gestisce il timeout freddo (riprova guidata invece di errore muto).
3. Default di persistenza di [Persistenza e identità di default](04-persistenza-identita-default.md): il bundle deve sopravvivere a reinstallazioni accidentali o scadere in fretta per non lasciare token in giro?

## Context

- `docs/RELAY-USER.md` (flusso Pair attuale in 4 passi + tabella errori) e schermata `lib/screens/relay_settings_screen.dart` con i bug live già corretti (`addPostFrameCallback`, `_FactRow` fingerprint).
- Tre valori del provisioning dalla summary di `create_relay.sh`: il prototipo li impacchetta, non li cambia.
- Vincoli: nessuna firma/chiave in più sul wire, token resta single-use con scadenza (default 168 h), confronto fingerprint fuori banda resta il check che prova l'identità del relay.

## Done when

- Un artefatto linkato (formato bundle + mock flusso, anche carta/stub) su cui l'utente ha reagito.
- Decisioni risultanti (formato, contenuto, TTL, gestione timeout freddo) scritte nella risoluzione come puntatori all'artefatto, non incollandolo.

## Resolution

Risolto in implementazione (la mappa porta l'esecuzione dentro di sé per questo
effort): il "prototipo da far reagire" è diventato il codice stesso, provato dal vivo.

1. **Formato**: `prysm-relay://pair?onion=<56>.onion&fpr=<hex64>&token=<hex64>`,
   `RelayPairingLink` in `packages/prysm_relay_protocol/lib/src/pairing_link.dart`.
   Sia QR sia link testuale — il QR è lo stesso URI, reso in blocchi unicode dal
   comando `prysm_relay pair-link` e verificato scansionandolo (decodifica identica
   alla riga `link:`). **Nessun TTL nel link**: l'autorità sulla scadenza è il relay,
   una copia potrebbe solo mentire. Il link è segreto quanto il token che contiene.
2. **Flusso app**: incolla / auto-detect nel campo indirizzo / scansione (solo
   Android), riempimento dei due campi e fetch automatico; il fingerprint del link
   diventa il riferimento contro cui l'app confronta il manifest da sola (match →
   riga di conferma, mismatch → Pairing bloccato come firma invalida). Timeout
   freddo: un secondo tentativo automatico a 60 s con testo esplicito invece
   dell'errore muto. Provato dal vivo end-to-end (link applicato, retry osservato,
   pairing completato, mismatch e link malformato respinti).
3. **Persistenza**: nessuna interazione — il link non viene mai persistito sul
   dispositivo, vive nel provisioning e nella clipboard; il token resta monouso con
   la scadenza decisa dal relay.

Fuori scope dichiarato: registrazione dello scheme presso il sistema operativo
(intent-filter `VIEW`, `.desktop` handler). Il link si incolla o si scansiona.
