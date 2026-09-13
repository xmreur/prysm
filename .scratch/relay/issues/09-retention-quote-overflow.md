# Retention, quote e comportamento in overflow

Type: grilling
Status: resolved
Blocked by: 01

## Question

Quanto e per quanto tempo un Relay conserva, e cosa succede quando si riempie?

1. **Limiti**: TTL per messaggio, byte totali per Mailbox, numero massimo di messaggi, dimensione
   massima del singolo messaggio. Quali sono nel Contract (negoziabili) e quali sono limiti duri del
   server?
2. **Overflow**: il Relay rifiuta il nuovo messaggio con errore tipizzato (e il mittente lo accoda
   localmente), scarta il piu' vecchio, o sospende il Contract? Chi viene informato: mittente,
   destinatario, entrambi?
3. **Cancellazione dopo il Pickup**: il Relay cancella appena consegna, o aspetta un ack esplicito del
   client? L'ack introduce uno stato in piu' ma evita la perdita se il client crasha durante il
   Pickup; senza ack, una sola consegna persa e' un messaggio perso per sempre.
4. **Cosa vede l'utente**: spazio usato, messaggi in attesa, scadenza piu' vicina. E come lo sapra',
   dato che l'app puo' chiederlo solo al Pickup.
5. **Default**: numeri concreti per la v1, distinti fra Private (generoso) e Public (prudente).

## Context

- Limiti inbound del client, come riferimento di scala: 96 MiB per messaggio, budget in volo 128 MiB,
  rate 30 richieste/10s per mittente e 200/10s globali (`lib/server/inbound_limits.dart`,
  `lib/server/inbound_rate_limiter.dart`).
- La coda locale del mittente ritenta fino a 50 volte con backoff ~2/4/8/16/30s
  (`lib/services/chat_service.dart:506`, `:599-602`): un rifiuto per quota piena non perde il
  messaggio, lo rimanda alla coda. Da confermare che il rifiuto sia classificato come ritentabile.
- `messageRetentionDays` esiste gia' lato client (`lib/models/settings.dart:24`): la retention del
  Relay e' un'altra cosa e non va confusa con quella (ne' nel codice ne' nella UI).

## Done when

- Tabella dei limiti con valori di default per Private e Public, e quali sono negoziabili.
- Politica di overflow decisa, con l'errore che il mittente riceve e la sua classificazione
  (ritentabile o definitivo).
- Cancellazione dopo Pickup decisa (con o senza ack) e conseguenze accettate.
- Cosa il Relay riporta all'utente al Pickup.

## Answer

Spec §3.1, §3.4, §4, §5.

- **Limiti** (nel Contract, negoziabili entro il manifest del Relay): `maxItemBytes`,
  `maxMailboxItems`, `maxTenantBytes`, `itemTtlSeconds`, `maxMailboxes`.
- **Default v1**: TTL **20 giorni** (allineato a chatmail `delete_mails_after` e al TTL ~21 giorni di
  SimpleX), `maxMailboxItems` 256 (SimpleX usa 128 per coda), `maxItemBytes` 1 MiB su Public / 8 MiB
  su Private, `maxTenantBytes` 64 MiB su Public / 256 MiB su Private, `maxMailboxes` 512.
- **Overflow = `reject`**, unica policy v1: il deposito nuovo viene rifiutato con `mailbox_full` /
  `tenant_full` (507, **ritentabile**), non si scarta il piu' vecchio. Perdere il messaggio nuovo e'
  visibile al mittente, che lo tiene in coda e riprova; perdere il piu' vecchio non e' visibile a
  nessuno. La coda locale ritenta fino a 50 volte con backoff ~2/4/8/16/30 s, quindi un rifiuto per
  quota piena non perde il messaggio. Lezione pagata da chatmail (issue relay#489): quota piena =
  account morto; qui il Pickup libera sempre spazio.
- **Cancellazione**: **dopo ack esplicito**, non al Pickup (`POST /relay/ack`). Un client che muore a
  meta' Pickup non perde nulla; il costo e' un round-trip in piu' e un id per item.
- **Cosa vede l'utente**: `POST /relay/status` restituisce item, byte, numero di mailbox e la
  scadenza piu' vicina; l'app lo mostra nella sezione Relay delle impostazioni (il dato si aggiorna
  al Pickup, che e' il solo momento in cui l'app parla col Relay).
- **Sweeper** lato server ogni 60 s: cancella gli item scaduti e compatta i token.
