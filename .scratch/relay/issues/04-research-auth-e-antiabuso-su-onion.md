# Prior art: come un servizio Tor-only autentica gli utenti e si difende dagli abusi

Type: research
Status: resolved

## Question

Un Relay non ha IP dei client, non ha DNS, non ha TLS con CA: e' un hidden service. Da accertare sulle
fonti primarie (tor-spec e rend-spec, documentazione Tor Project, sorgente Briar, documentazione
operativa di onion service ad alto traffico):

1. **Onion service client authorization v3**: come funziona, cosa impedisce davvero, come si
   distribuiscono le chiavi ai client, quali limiti pratici ha (numero di client, rotazione).
2. **Proof-of-work defense** degli onion service (la difesa introdotta contro il flooding): come si
   configura, cosa costa al client legittimo, quando conviene.
3. **Rate limiting senza IP**: su cosa si limita quando ogni connessione arriva dal circuito Tor
   locale; pratiche documentate (token, identita', per-circuito).
4. **Pairing di Briar Mailbox**: forma del token, chi lo genera, come si prova il possesso, come si
   revoca.
5. **Abusi noti** contro depositi anonimi (storage gratuito, amplificazione, riempimento disco) e
   contromisure documentate.

## Done when

- Findings in `.scratch/relay/research/04-auth-e-antiabuso-su-onion.md`, con citazioni puntuali.
- Una sezione "cosa e' applicabile a un Relay Prysm in Dart", che distingua quello che dipende da Tor
  (torrc, configurazione) da quello che dipende dal protocollo applicativo.
- Una nota esplicita su cosa **non** funziona in questo contesto, per evitare di riproporlo (es.
  qualunque difesa basata su IP o geolocalizzazione).

## Answer

Findings: `../research/04-auth-e-antiabuso-su-onion.md`.

1. **Client-auth v3**: file `.auth` (`descriptor:x25519:<pubkey>`) in `authorized_clients/`, client con `.auth_private` via `ClientOnionAuthDir`; senza chiave non si decifra il descriptor (niente intro point). Distribuzione manuale out-of-band; revoca solo con restart tor; nessun control-port lato servizio.
2. **PoW**: `HiddenServicePoWDefensesEnabled 1` (+ QueueRate 250 / QueueBurst 2500 default), dormiente a effort 0, costo ~0 a riposo; sotto attacco puzzle Equi-X automatico lato client; richiede C Tor >= 0.4.8.1-alpha con modulo pow + build GPL.
3. **Rate limit senza IP**: IP inutilizzabile (solo localhost); Tor offre intro-DoS rate/burst, PoW queue, `HiddenServiceMaxStreams(CloseCircuit)`; l'app distingue i circuiti solo con `HiddenServiceExportCircuitID`, altrimenti limita per identita'/token applicativi.
4. **Briar pairing**: bearer 32-byte hex; setup token single-use via QR consumato con `PUT /setup` → owner token; token contatti generati da Briar via `POST /contacts`; revoca solo con wipe (`DELETE /`) o rimozione contatto.
5. **Abusi**: intro flooding → PoW + intro-DoS + Onionbalance; circuiti aggressivi → stream cap + kill via ExportCircuitID; riempimento disco → solo difese applicative (capability per folder stile Briar, quote/TTL, contratto firmato).

Applicabilita': Tor-side (PoW, intro-DoS, stream cap, ExportCircuitID, client-auth opzionale) vs app-side (contratto firmato, capability token, quote/TTL). NON funzionano: IP/geolocalizzazione/reputazione, CAPTCHA terze parti, TLS-CA, PoW-come-auth, client-auth-come-ratelimit.
