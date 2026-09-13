# Gruppi: fan-out e cosa vede il Relay

Type: grilling
Status: resolved
Blocked by: 01, 05

## Question

1. **Chi fa il fan-out**: resta il mittente (un deposito per membro, sul Relay **di quel membro**) e il
   Relay non sa nulla dei gruppi? Oppure il Relay accetta un messaggio e lo distribuisce (e allora
   deve conoscere la membership: leak grosso, e responsabilita' nuova)?
2. **`groupId`**: il Relay lo vede? Gli serve per qualcosa, o e' solo metadato regalato?
3. **Messaggi di controllo** (`control-wrap-2`: inviti, rotazione epoca, rimozioni) attraverso il
   Relay: si comportano come i messaggi normali o hanno bisogno di garanzie diverse (ordine, urgenza,
   scadenza)? Un invito consegnato tre giorni dopo e' ancora valido?
4. **History Backfill** (`group-history-relay`, che con il Relay non ha nulla a che fare ma passa per
   la stessa strada): puo' attraversare un Relay, considerando che oggi le righe pendenti di backfill
   vengono scartate all'avvio (`lib/services/group_service.dart:1083-1093`)?
5. **Membri senza Relay**: restano in coda locale, e il gruppo diventa parzialmente asincrono. Si
   accetta, o l'utente deve vederlo?

## Context

- Il fan-out e' gia' per-membro e per-riga: righe pending con id `<msgId>__<memberId>`
  (`lib/services/group_chat_service.dart:629`), postman dedicato
  (`_GroupChatTransportPostman`, `:871-901`). La forma dei dati per un fan-out via Relay c'e' gia'.
- Deduplica gruppo lato ricevente: `(senderId, index)` con claim/resolve su `group_inbound_seen`
  (`lib/util/group_sender_index_store.dart`, `lib/server/inbound_message_router.dart:625-633`);
  l'ordine non conta, il duplicato viene ack-and-droppato. Consegne doppie da Relay sono innocue.
- I gate "non-membro" e "pre-join" fanno ack-and-drop: la storia prima dell'ingresso non viene
  archiviata per scelta.
- Due membri dello stesso gruppo che non sono contatti reciproci non riescono a formare un link WS
  (`lib/transport/inbound_ws_peer_link.dart:229-237`): nel lab il loro primo messaggio ha preso 134 s
  (regola 17 di `live-app-testing`). Il Relay potrebbe migliorare proprio questo caso.

## Done when

- Deciso chi fa il fan-out (e se il Relay resta ignaro dei gruppi).
- Deciso il destino di `groupId` verso il Relay.
- Deciso il trattamento dei messaggi di controllo, incluse scadenze se servono.
- Deciso cosa vede l'utente quando parte del gruppo non e' raggiungibile.

## Answer

Spec §1, §8.

- **Fan-out lato mittente**, il Relay resta ignaro dei gruppi: un deposito per membro, sul Relay *di
  quel membro*, all'indirizzo che quel membro ha pubblicato per il mittente. La forma dei dati
  esiste gia': righe pendenti per-membro `<msgId>__<memberId>`
  (`lib/services/group_chat_service.dart:629`) e `_GroupChatTransportPostman` (`:871-901`).
- **`groupId` invisibile**: sta dentro il sigillo come ogni altro campo. Il Relay non puo' correlare i
  membri di un gruppo se non per co-occorrenza temporale dei depositi su indirizzi diversi (rischio
  accettato, vedi threat model).
- **Messaggi di controllo** (`control-wrap-2`: inviti, rotazione epoca, rimozioni): stesso percorso,
  nessuna garanzia aggiuntiva e **nessuna scadenza** nella v1. Un invito consegnato tre giorni dopo
  resta valido: la validita' e' crittografica, non temporale, e introdurre scadenze qui vorrebbe dire
  toccare la semantica dei gruppi — fuori scope. Il TTL della Mailbox (20 giorni) e' l'unico limite.
- **History Backfill** (`group-history-relay`, che col Relay non ha niente a che fare): **non**
  attraversa il Relay nella v1, perche' oggi le righe pendenti di backfill vengono scartate
  all'avvio (`lib/services/group_service.dart:1083-1093`): relayarle contraddirebbe una decisione
  gia' presa altrove.
- **Membri senza Relay**: restano in coda locale e ricevono quando tornano online, come oggi. Non
  viene mostrato nulla di nuovo all'utente nella v1 (nessuno stato "consegnato a N su M"): sarebbe
  uno sforamento del budget UI. In nebbia insieme alla delivery receipt.
- Bonus atteso: due membri non-contatti reciproci oggi non riescono a formare un link WS
  (`lib/transport/inbound_ws_peer_link.dart:229-237`, primo messaggio misurato a 134 s nel lab). Con
  un Relay quel caso diventa un deposito normale — da verificare dal vivo.
