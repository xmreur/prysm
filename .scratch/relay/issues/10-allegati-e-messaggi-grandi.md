# Allegati e messaggi grandi attraverso il Relay

Type: grilling
Status: resolved
Blocked by: 01, 09

## Question

Gli allegati passano dal Relay, e come?

1. **Cap contrattuale**: il Relay accetta messaggi fino a N byte dichiarati nel Contract (quale N di
   default?) e sopra quella soglia il mittente **non** usa il Relay, accodando localmente. Semplice,
   ma "la foto non arriva mai se non sei online" e' un comportamento che l'utente deve capire.
2. **API blob separata**: upload a chunk verso il Relay, download a chunk al Pickup, con un
   riferimento dentro il messaggio. Piu' lavoro e piu' stato (upload parziali, garbage collection),
   ma gli allegati funzionano davvero in asincrono.
3. **Niente allegati nella v1**: solo testo e side-channel (reazioni, ricevute, modifiche, timer).

E la domanda a valle: cosa vede il Relay comunque, dato che `fileName` e `fileSize` sono campi in
chiaro dell'envelope, e se vanno spostati.

## Context

- Il trasferimento file grande **non e' un POST**: e' un chunked transfer su WebSocket
  (`fileTransferChunkMagic`, `FileTransferChunkFrame`, `wsFileTransferOps` in
  `lib/transport/ws_protocol.dart`), online-to-online per costruzione. Un Relay store-and-forward non
  puo' parteciparvi: il mittente dovrebbe degradare al POST monolitico.
- Il POST monolitico esiste e regge fino a 96 MiB per messaggio, con budget in volo 128 MiB
  (`lib/server/inbound_limits.dart`), e il client usa un timeout di 5 minuti per i media grandi
  (`lib/services/chat_service.dart`, `_sendOverTor`).
- La chiave del file e' avvolta per il peer (`file-signed-1`, `wrappedKey`): il contenuto resta
  cifrato per il Relay, ma nome e dimensione no.

## Done when

- Strada scelta per la v1, con il numero di default se e' il cap.
- Deciso cosa accade al percorso WS chunked quando il destinatario e' offline (degrado o coda).
- Deciso se `fileName`/`fileSize` restano in chiaro verso il Relay.
- Quello che non entra nella v1 finisce in nebbia con la forma che avrebbe.

## Answer

Deciso: **(1) cap contrattuale**, nessuna API blob nella v1. Spec §3.4, §8.

- `maxItemBytes` di default **1 MiB** (Public) e **8 MiB** (Private): copre testo, reazioni,
  ricevute, modifiche, timer, messaggi di controllo gruppo e immagini piccole.
- Sopra il cap il mittente **non** usa il Relay: il messaggio resta nella coda locale per la consegna
  diretta, esattamente come oggi. Il Relay risponde `413 item_too_large` (non ritentabile), quindi il
  client non ci ritorna sopra.
- Il **chunked transfer su WebSocket** (`fileTransferChunkMagic`, `wsFileTransferOps`) resta
  direct-only: e' un protocollo fra due peer vivi, non sopravvive allo store-and-forward. Il
  degrado non e' automatico verso il POST monolitico: se il file supera il cap, si aspetta il peer.
- `fileName` e `fileSize` **non** sono piu' esposti: viaggiano dentro il sigillo come tutti gli altri
  campi dell'envelope, quindi il Relay vede solo la lunghezza del blob.
- In nebbia, con la forma che avrebbe: `POST /relay/blob/init|chunk|commit` + riferimento dentro
  l'envelope sigillato, con garbage collection degli upload parziali.
