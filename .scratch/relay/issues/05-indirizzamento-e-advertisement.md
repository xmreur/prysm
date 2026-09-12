# Indirizzamento della Mailbox e Advertisement del Relay

Type: grilling
Status: resolved
Blocked by: 01

## Question

Come fa un mittente a sapere **dove** lasciare un messaggio per un peer che e' offline?

1. Che forma ha l'**Advertisement**? Proposta da discutere: lista ordinata di record
   `{relayOnion, mailboxAddress, capabilities, validFrom, validTo}` firmati dall'Identity del
   destinatario. Quali campi sono davvero necessari nella v1?
2. **Dove viene pubblicato**: in `/profile`, nel payload QR / scambio contatto, in entrambi?
3. **Dove viene cachato dal mittente e per quanto**: oggi la tabella `users` non ha una colonna per
   questo, e serve una decisione su TTL e rinnovo.
4. **Cosa fa il mittente** se l'Advertisement e' scaduto, se il Relay rifiuta, se il Relay non
   risponde: degrada a coda locale, prova il Relay successivo, o segnala all'utente?

## Context

- Paradosso da risolvere: `/profile` e' servito dall'hidden service **del destinatario**
  (`buildProfile`, `lib/server/inbound_message_router.dart:99-126`), quindi un Advertisement
  ottenibile solo con fetch live e' inutile proprio quando serve. Deve essere appreso prima:
  allo scambio contatto (`lib/services/contact_add_service.dart:157-196`) o dall'ultimo profilo visto,
  e **persistito**.
- `buildProfile` redige il profilo per richiedenti sconosciuti o bloccati: l'Advertisement eredita
  quella policy o ne vuole una sua?
- Il payload QR e' `prysm:v2:onion:fingerprint` (`lib/util/qr_payload.dart:13-15`): aggiungere il
  Relay significa una `v3` del payload, con i lettori vecchi da considerare.
- Dialare un onion arbitrario funziona gia': l'indirizzo del peer **e'** `Contact.id`, interpolato in
  `http://$peerOnion:80/...`. Nessuna modifica a Tor lato client.

## Done when

- Schema del record deciso, con chi firma cosa.
- Punti di pubblicazione decisi (profilo, QR, contatto) e versione del payload QR.
- Cache e TTL lato mittente decisi, inclusa la colonna/tabella dove vive.
- Comportamento di fallback deciso per ognuno dei tre fallimenti (scaduto, rifiutato, muto).

## Answer

Spec: [`relay-protocol-v1.md`](../proto/relay-protocol-v1.md) §2.

- **Forma**: `relay: {v, issuedAt, expiresAt, relays:[{onion, deposit, maxItemBytes, blockSize}], sig}`,
  firmato Ed25519 dall'identita' del proprietario su
  `prysm-relay-advert-1|<ownerFpr>|<issuedAt>|<expiresAt>|<onion>|<deposit>|…`. La firma e' il punto
  centrale: un Advertisement in cache resta **verificabile offline**, cioe' proprio quando il
  proprietario e' irraggiungibile.
- **Lista ordinata dalla v1**, ma un solo Relay attivo: cambiare quel campo dopo sarebbe breaking, e
  la ridondanza e' sicura da rimandare perche' la dedup inbound e' idempotente.
- **Pubblicazione**: in `GET /profile?requester=` (per-richiedente, quindi l'indirizzo e'
  per-contatto) ed erede della redazione di `buildProfile`: a chi verrebbe redatto oggi
  (sconosciuto/bloccato) l'Advertisement non si pubblica. Il QR **non** cambia nella v1: il payload
  `prysm:v2:onion:fingerprint` resta, e l'Advertisement si impara al primo fetch del profilo (che
  avviene comunque, perche' aggiungere un contatto richiede il peer online).
- **Cache lato mittente**: nuova colonna `users.relayAdvertisement` (TEXT JSON) in `chat_app.db`,
  migrazione v18 -> v19, scritta da `PeerIdentityResolver` a ogni fetch riuscito. Scaduto o assente
  -> nessuna consegna via Relay.
- **Fallback**: advertisement scaduto, Relay muto o errore non ritentabile -> il messaggio resta
  nella coda locale per la consegna **diretta**, esattamente come oggi. Errori ritentabili
  (`mailbox_full`, `tenant_full`, `rate_limited`, `internal`, `stale_request`) -> ritenta piu' tardi.
