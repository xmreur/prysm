# Il Contract: schema, negoziazione, firme, revoca, versioning

Type: prototype
Status: resolved
Blocked by: 05, 06, 07, 08, 09, 10, 11, 12, 13

## Question

Che forma **concreta** ha un Contract? Questo ticket non discute in astratto: produce un artefatto su
cui reagire, perche' a questo punto tutte le decisioni a monte sono chiuse e il Contract e' la loro
sintesi.

Da prototipare (chiamare la skill `prototype`, opzione LOGIC):

1. **JSON di esempio** di un Contract firmato, in due varianti: Private Relay minimale e Public Relay
   con quote strette.
2. **Tipi Dart** corrispondenti in `packages/prysm_relay_protocol` (immutabili, con
   `fromJson`/`toJson`, nello stile di `lib/models/settings.dart`).
3. **Validazione**: cosa rifiuta il Relay e cosa rifiuta il client, con errori tipizzati.
4. **Flusso in tre atti**: manifest firmato del Relay -> richiesta firmata dell'utente (opzioni scelte
   entro i limiti del manifest) -> ricevuta di Contract firmata dal Relay. Chi conserva cosa.
5. **Ciclo di vita**: scadenza, rinnovo, revoca da entrambi i lati, e cosa accade alla Mailbox in ogni
   caso.
6. **Versioning**: come si evolve il Contract senza rompere i Relay vecchi (campo di versione,
   capability sconosciute ignorate o rifiutate?).

## Done when

- L'artefatto esiste nel repo (package o `.scratch/relay/proto/`) e il ticket lo linka.
- Ogni campo del Contract e' tracciabile alla decisione che lo ha prodotto (il ticket che lo ha
  deciso), senza campi orfani "che potrebbero servire".
- L'utente ha reagito all'artefatto e le correzioni sono dentro.
- Gli errori tipizzati sono elencati, con quali sono ritentabili dal mittente.

## Answer

Artefatto prodotto: **[`relay-protocol-v1.md`](../proto/relay-protocol-v1.md)** (spec normativa
completa) + i tipi Dart in `packages/prysm_relay_protocol` con round-trip JSON e validazione.

- **Contract** (§4): `protocol, version, relayFingerprint, relayOnion, ownerFingerprint, ownerOnion,
  tenancy, limits{maxItemBytes, maxMailboxItems, maxTenantBytes, itemTtlSeconds, maxMailboxes,
  blockSize}, overflow, issuedAt, expiresAt, sig`. Firma del Relay su
  `prysm-relay-contract-1|<JSON canonico di tutti i campi tranne sig>` (chiavi ordinate, nessuno
  spazio) — canonicalizzazione necessaria, altrimenti la firma dipende dall'ordine di serializzazione.
- **Flusso in tre atti** (§3.1, §3.2): manifest firmato del Relay -> richiesta firmata dell'utente
  con le opzioni scelte -> Contract firmato dal Relay, con le opzioni **clampate** ai limiti del
  manifest. Il client rifiuta un Contract il cui `relayFingerprint` non corrisponde al manifest su
  cui ha fatto Pairing.
- **Ciclo di vita**: `expiresAt` nullable (Private: nessuna scadenza); rinnovo = nuovo pair con token
  fresco, idempotente sulla stessa identita' (`version` incrementa); revoca = `unpair`, che cancella
  tenant, mailbox e item.
- **Versioning**: `protocol` e' un id esatto (`prysm-relay/1`) e viene rifiutato se diverso; i campi
  sconosciuti dentro `limits` sono **ignorati** in lettura (estendibile) mentre un `protocol`
  sconosciuto e' un errore (`bad_request`). Nessuna negoziazione di versione nella v1: un solo
  numero, rifiuto secco.
- **Errori tipizzati** con ritentabilita' dichiarata: tabella in §3.9. E' la parte che il client
  consuma per decidere se tenere il messaggio in coda o abbandonare il Relay per quel messaggio.
- Ogni campo e' tracciabile al ticket che lo ha deciso (§ corrispondenti); nessun campo "che potrebbe
  servire".
