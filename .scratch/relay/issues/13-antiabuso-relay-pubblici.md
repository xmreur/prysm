# Registrazione e anti-abuso per i Public Relay

Type: grilling
Status: resolved
Blocked by: 04, 06, 09

## Question

Come fa un Public Relay ad accettare sconosciuti senza diventare storage gratuito per chiunque?

1. **Ammissione**: aperta, su invito (token dall'operatore), con proof-of-work, o con approvazione
   manuale? Quale entra nella v1?
2. **Quote per Identity** (oltre alle quote per Mailbox del ticket sulle quote): quante Mailbox per
   Identity, quanti Contract contemporanei, tetto di banda.
3. **Rate limit**: su cosa si limita, dato che non esistono IP e ogni connessione arriva dal Tor
   locale? Per Identity del mittente, per Mailbox di destinazione, per circuito?
4. **Sanzioni**: cosa succede a chi sfora — rifiuto temporaneo, sospensione del Contract, ban
   dell'Identity. E come lo comunica.
5. **Manifest dell'operatore**: il Relay pubblica un documento firmato con i suoi termini (limiti,
   retention, log conservati, giurisdizione)? E' quello che l'utente vede prima del Pairing.
6. **Cosa l'operatore puo' sapere e cosa promette di non fare**: i log del Relay sono un rischio per
   gli utenti; va deciso cosa e' lecito loggare.

## Context

- Il client ha gia' un rate limiter a finestra fissa con chiave namespaced e chiave globale
  (`lib/server/inbound_rate_limiter.dart`): e' il modello da riusare nel Relay, non da reinventare.
- La difesa proof-of-work degli onion service e la client authorization v3 sono materia del ticket di
  ricerca corrispondente: qui si decide **se** e **quando** usarle.
- Un Private Relay e' lo stesso binario con un solo tenant: le decisioni qui non devono complicare
  quel caso (default prudente, ma spegnibile).

## Done when

- Modalita' di ammissione della v1 decisa, con le altre in nebbia.
- Quote e rate limit decisi con valori concreti e la loro chiave.
- Sanzioni decise, con cosa vede chi le subisce.
- Deciso se esiste il manifest firmato e cosa contiene.
- Decisa la policy di logging del Relay (cosa non si scrive mai su disco).

## Answer

Spec §3.1, §3.2, §3.9, §5.

- **Ammissione v1**: `invite` come default anche per i Public Relay (token monouso con scadenza
  emessi dall'operatore); `open` esiste nel config ma va abilitata a mano e il manifest la dichiara;
  `closed` blocca ogni nuovo Contract. Nessun proof-of-work applicativo: la ricerca e' chiara,
  **PoW prova effort, non identita'** e non sostituisce un contratto firmato. La difesa PoW che serve
  e' quella di **Tor**, non nostra.
- **Difese lato Tor**, da documentare nel runbook di deploy e non da implementare:
  `HiddenServicePoWDefensesEnabled 1` (C Tor >= 0.4.8.1-alpha, dormiente a riposo),
  `HiddenServiceEnableIntroDoSDefense 1`, `HiddenServiceMaxStreams` + `HiddenServiceMaxStreamsCloseCircuit 1`.
- **Difese applicative**: quote per tenant e per mailbox (ticket retention), rate limit a finestra
  fissa — 60 depositi/min per indirizzo, 30 pickup/min per tenant, 10 pair/ora — modellati su
  `lib/server/inbound_rate_limiter.dart`. La chiave e' l'**identita' applicativa** (owner
  fingerprint) o il deposit address, **mai l'IP**: l'app vede solo `localhost`, e ogni difesa basata
  su IP, geolocalizzazione o reputazione e' inapplicabile per costruzione.
- **Sanzioni**: `429 rate_limited` e `507 *_full` (entrambi ritentabili), `403 admission_closed` /
  `bad_token` per l'ammissione. Nessun ban permanente nella v1: l'operatore revoca il Contract
  (rimozione del tenant), che e' l'unica sanzione che ha senso quando non esistono identita' di
  mittente.
- **Manifest firmato** come termini pubblici: limiti, retention, tenancy, ammissione, testo libero
  dell'operatore. E' cio' che l'utente vede **prima** del Pairing.
- **Policy di log**: default `counters` — mai un deposit address oltre i primi 6 hex, mai un payload,
  mai un onion di proprietario. `debug` esiste ma avvisa all'avvio. I log di un Relay sono un rischio
  per i suoi utenti, non un comfort per l'operatore.
