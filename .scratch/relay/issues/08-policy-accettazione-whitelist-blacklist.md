# Policy di accettazione: whitelist/blacklist e chi detiene la verita'

Type: grilling
Status: resolved
Blocked by: 01

## Question

L'utente vuole dire al Relay da chi accettare. Su **cosa** filtra il Relay, e chi vince quando Relay
e client dissentono?

1. **Chiave del filtro**: Prysm ID del mittente, Fingerprint dell'Identity, o token per-contatto?
   Attenzione alla tensione diretta con il modello dei metadati: se il mittente e' opaco al Relay, il
   Relay **non puo'** filtrare per mittente, e la whitelist diventa una lista di indirizzi di deposito
   distinti per contatto (che e' anche un modo di ottenere la whitelist *senza* rivelare la rubrica).
2. **Modalita'**: whitelist stretta (solo questi), blacklist (tutti tranne questi), "solo contatti
   noti" (e allora il Relay deve conoscere un derivato della rubrica), soglie ("massimo N messaggi da
   uno sconosciuto").
3. **Rapporto col client**: `refuseUnknownSenders` e `BlockService` esistono e decidono lato client
   (`lib/models/settings.dart:30`, `_senderRefused` in
   `lib/server/inbound_message_router.dart:933`). Il Relay ne e' una copia sincronizzata, un filtro
   indipendente, o la stessa policy pubblicata in forma derivata? Chi e' la verita'?
4. **Cosa risponde il Relay a un mittente rifiutato**: errore tipizzato (rivela la policy) o accept
   silenzioso e drop (costa banda e storage)? Il client oggi fa ack-and-drop proprio per non rivelare.
5. **Quali altre funzioni** l'utente puo' chiedere al Relay in questa famiglia: tetto per mittente,
   solo messaggi sotto N byte, no allegati, orari, sospensione temporanea ("non ricevere nulla").

## Context

- Il client ack-and-droppa gia' in piu' punti proprio per non rivelare la propria policy (mittente
  rifiutato, non-membro di un gruppo, pre-join): lo stesso principio va deciso per il Relay.
- La rubrica e' un dato sensibile: qualunque sincronizzazione di whitelist verso un Public Relay
  consegna la lista dei contatti, se fatta in chiaro.

## Done when

- Chiave del filtro decisa, coerente con il modello dei metadati.
- Insieme minimo di modalita' della v1 deciso (le altre in nebbia).
- Regola di precedenza Relay/client scritta, con l'invariante "il Relay non puo' allargare cio' che il
  client rifiuta".
- Risposta al mittente rifiutato decisa.

## Answer

Spec §2, §3.3, §3.4.

- **Chiave del filtro**: il **deposit address**, non il mittente. Un indirizzo per contatto: chi lo
  conosce deposita, chi non lo conosce no. Il Relay non vede mai un'identita' di mittente, quindi non
  puo' filtrare per mittente — ed e' un vantaggio, non una rinuncia: la whitelist esiste **senza**
  che il Relay conosca la rubrica (il campo `label` e' opaco e puo' essere omesso).
- **Modalita' v1**: whitelist implicita (esistenza dell'indirizzo) + `disable` per sospendere senza
  perdere gli item + `delete` per revocare + tetti opzionali per indirizzo (`maxItems`, `maxBytes`).
  Nessuna blacklist: in questo modello non ha senso, non essendoci identita' da elencare.
- **Rapporto col client**: nessuna sincronizzazione di liste, quindi nessun leak. `BlockService` e
  `refuseUnknownSenders` restano la verita' lato client e continuano a valere **dopo** il Pickup
  (l'envelope passa dalla stessa pipeline). Invariante: **il Relay non puo' allargare cio' che il
  client rifiuta**; puo' solo restringere prima. Bloccare un contatto nell'app deve quindi anche
  `delete` il suo indirizzo (azione client, non policy del Relay).
- **Risposta a un mittente rifiutato**: `404 mailbox_unknown`, **identica** per "mai esistito" e
  "revocato" — chi sonda non impara niente. E' lo stesso principio dell'ack-and-drop del client e del
  `404` invece di `403` di Briar Mailbox.
- **Sospensione temporanea** ("non ricevere nulla"): `disable` su tutti gli indirizzi. In nebbia:
  orari, tetti per mittente piu' fini, "solo messaggi sotto N byte".
