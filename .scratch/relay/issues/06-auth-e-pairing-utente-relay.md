# Autenticazione e Pairing utente<->Relay

Type: grilling
Status: resolved
Blocked by: 01, 04

## Question

Come si stabilisce un Contract, e come si prova ad ogni richiesta successiva che sono io?

1. **Pairing**: il Relay stampa un token (dal suo config) che l'utente incolla nell'app? O l'app
   genera una richiesta firmata che l'operatore approva? Come si mostra all'utente il Relay che sta
   accettando (fingerprint del Relay, nome, onion)?
2. **Prova di identita' ricorrente**: firma Ed25519 su un contesto tipizzato, come le `PeerProof` che
   esistono gia', o un token di sessione emesso dal Relay? Quanto vale, come si rinnova?
3. **Prova di possesso dell'onion**: serve? Un Relay deve sapere che chi firma controlla anche
   l'hidden service a cui i messaggi sono indirizzati, altrimenti chiunque puo' aprire una Mailbox per
   l'onion di un altro (e intercettare cosa il Relay accetta per lui).
4. **Revoca e rotazione**: come si chiude un Contract, cosa succede ai messaggi ancora in Mailbox, e
   cosa accade se l'utente perde le chiavi o cambia onion.
5. **Onion client authorization**: il Relay ne fa uso per essere raggiungibile solo dai suoi utenti
   (Private Relay), o resta aperto e filtra a livello applicativo?

## Context

- Lo schema di firma esiste gia' e va riusato, non reinventato: `PeerProof` firma
  `contesto|sender|receiver|timestampMs` con tolleranza 5 minuti, contesti `prysm-ws-hello-1` e
  `prysm-sync-hint-1` (`lib/crypto/peer_proof.dart`), verificati a 64 byte.
- Precedente di autenticazione inbound: `InboundWsPeerLink.acceptIncoming` accetta hello solo da peer
  **gia' noti** (risoluzione identita' cache-only per scelta,
  `lib/transport/inbound_ws_peer_link.dart:229-237`) — un Relay ha il problema inverso: deve accettare
  il primo contatto di uno sconosciuto in modo controllato.
- `GET /profile` e' l'unico punto dove un terzo puo' leggere l'identita' di un onion, e redige gli
  sconosciuti: una challenge su `/profile` come prova di possesso va verificata contro quella policy.

## Done when

- Flusso di Pairing deciso passo per passo, con cosa vede l'utente e cosa vede l'operatore.
- Schema di firma deciso (contesti nuovi, in stile `prysm-relay-*`), con scadenze e anti-replay.
- Prova di possesso dell'onion: decisa, o esplicitamente accettata come rischio con motivazione.
- Revoca, rotazione e perdita chiavi: deciso cosa accade alla Mailbox.

## Answer

Spec: [`relay-protocol-v1.md`](../proto/relay-protocol-v1.md) §3.1, §3.2, §3.9, §4.

- **Pairing** stile Briar Mailbox: il Relay genera un **setup token** (32 byte hex, monouso, con
  scadenza) via CLI; l'utente lo incolla (o scansiona) nell'app; `POST /relay/pair` porta identita',
  onion, opzioni richieste e firma su `prysm-relay-pair-1|<relayFpr>|<ownerFpr>|<token>|<ts>`. Il
  Relay clampa le opzioni ai propri limiti e restituisce il **Contract firmato**. Prima del pairing
  l'app mostra `GET /relay/manifest` — firmato — cosi' l'utente vede *chi* sta accettando e *cosa*
  promette.
- **Auth ricorrente**: nessun token di sessione. Tre header (`X-Prysm-Owner`, `X-Prysm-Timestamp`,
  `X-Prysm-Signature`) con firma Ed25519 su
  `prysm-relay-auth-1|<relayFpr>|<ownerFpr>|<METHOD> <path>|<ts>|<sha256(body)>`; skew ±300 s e cache
  dei digest visti per 600 s contro il replay. E' lo stesso schema di `PeerProof`
  (`lib/crypto/peer_proof.dart`) esteso a metodo, path e corpo: riusato, non reinventato.
- **Prova di possesso dell'onion**: **non** richiesta nella v1, e il rischio e' accettato
  consapevolmente. Motivo: aprire una Mailbox per l'onion di un altro non da' accesso a nulla (i
  depositi altrui vanno su indirizzi che l'attaccante non conosce, e il sigillo e' verso la chiave
  del vero destinatario), costa solo quota al Relay — e la quota e' governata da ammissione e
  limiti. `ownerOnion` nel Contract resta informativo.
- **Revoca/rotazione**: `POST /relay/unpair` cancella tenant, mailbox e item (irreversibile: il punto
  e' non lasciare nulla). Rotazione di un indirizzo = `mailbox put` del nuovo + `delete` del vecchio.
  Perdita delle chiavi = perdita del Contract: nuovo pairing con nuovo token, e la vecchia Mailbox
  scade per TTL. Cambio di onion: nuovo Advertisement, nessun impatto sul Relay.
- **Client authorization v3 di Tor**: fuori dalla v1 (revoca solo con restart di tor, distribuzione
  chiavi manuale). Resta consigliata in documentazione come hardening di un Private Relay.
