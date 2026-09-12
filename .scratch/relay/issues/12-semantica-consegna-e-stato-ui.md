# Semantica di consegna e stato mostrato in UI

Type: grilling
Status: resolved
Blocked by: 01, 05

## Question

Quando il mittente deposita nel Relay, il messaggio e' "inviato"?

1. **Stato**: teniamo `sent` come oggi (il Relay ha accettato = 2xx), o introduciamo uno stato
   distinto tipo "in deposito"? Il secondo e' piu' onesto e costa una colonna di stato, una mappatura
   in UI e una stringa localizzata per lingua.
2. **Ricevuta del Relay**: il Relay firma una ricevuta di deposito? La conserviamo (dove?) o basta il
   2xx? Serve a qualcosa lato utente o solo in fase di diagnosi?
3. **Delivery receipt vera**: il Relay puo' dire "il destinatario ha ritirato". Oggi in Prysm **non
   esiste** alcuna delivery receipt: c'e' solo la read receipt. La aggiungiamo qui (e diventa una
   feature nuova visibile, con tutto cio' che implica in termini di privacy: il destinatario rivela
   quando torna online) o la rifiutiamo?
4. **Caso limite**: il Relay accetta e il destinatario non ritira mai. Dopo quanto, e come, lo mostra
   l'app al mittente?
5. **Footprint**: uno stato nuovo in UI e' dentro la seam 5 del budget o e' uno sforamento? Decidere
   consapevolmente, non per inerzia.

## Context

- Oggi `_sendOverTor` tratta **qualunque 2xx** come inviato e chiama `_markAsSent`
  (`lib/services/chat_service.dart:853-858`); il `failed` che l'utente vede e' solo uno stato di
  stream, la riga in DB resta `pending` (`:549-556`).
- Il 200 del ricevente e' deliberatamente ambiguo: significa "accettato", e copre anche l'ack-and-drop
  (non-membro, pre-join, duplicato, self-send). Il Relay eredita questa ambiguita' o la rompe?
- La read receipt e' un messaggio cifrato side-channel con la sua coda
  (`lib/services/read_receipt_service.dart`), governata da `sendReadReceipts`: una delivery receipt
  dovrebbe avere un interruttore proprio, non ereditare quello.
- Gli stati in `messages.status` sono stringhe (`sent`, `pending`, `received`, `pending_auth`,
  `quarantined`): aggiungerne uno tocca le query e le viste, non solo la UI.

## Done when

- Deciso se nasce uno stato nuovo, e se si' il suo nome e dove appare.
- Decisa la sorte della ricevuta di deposito.
- Decisa la delivery receipt: dentro o fuori, con il perche' in termini di privacy.
- Deciso cosa mostra l'app quando il deposito non viene mai ritirato.

## Answer

Deciso: **nessuno stato nuovo nella v1**. Spec §6.

- Il messaggio accettato dal Relay resta `sent`, esattamente come oggi quando l'HTTP di un peer
  risponde 2xx (`ChatService._markAsSent`, `lib/services/chat_service.dart:853-858`). Aggiungere un
  valore a `messages.status` toccherebbe query, viste, mappature e stringhe localizzate in due
  lingue: e' uno sforamento del budget di footprint per un guadagno informativo che nessuno ha
  chiesto.
- **Ricevuta di deposito**: `{status:'stored', itemId, expiresAt}`, **non firmata** nella v1. Una
  firma servirebbe solo a provare a terzi che il Relay ha accettato, e non abbiamo un consumatore per
  quella prova. Il client non la persiste: la usa per il log di diagnosi.
- **Delivery receipt vera** ("il destinatario ha ritirato"): **fuori dalla v1**, e non per costo ma
  per privacy: direbbe al mittente quando il destinatario e' tornato online, che e' un'informazione
  che oggi Prysm non rivela. Se entrera', dovra' avere un interruttore proprio, non ereditare
  `sendReadReceipts`.
- **Deposito mai ritirato**: l'app del mittente non mostra nulla di diverso. Il Relay applica il TTL
  (20 giorni) e l'item scade. In nebbia: stato "in deposito", eta' del deposito, e la receipt di
  ritiro come unico modo onesto di distinguere "consegnato" da "depositato".
