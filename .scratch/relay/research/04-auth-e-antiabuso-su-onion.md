# Auth e antiabuso per un servizio Tor-only (research)

## 1. Onion service client authorization v3

**Come funziona (rend-spec, Appendix G `RESTRICTED-DISCOVERY-MGMT`):**
il servizio popola `<HiddenServiceDir>/authorized_clients/` con un file `.auth` per client,
formato `descriptor:x25519:<base32-pubkey>`; se tor trova almeno un file valido, l'authorization
si attiva per quel servizio (https://spec.torproject.org/rend-spec/restricted-discovery.html).
Lato client, `torrc` dichiara `ClientOnionAuthDir <DIR>` e ogni file `.auth_private` contiene
`<56-char-onion-addr>:descriptor:x25519:<base32-privkey>` (stessa sezione di spec).
Nota di spec: la coppia e' generata da "a third party tool" e la pubblica va trasferita
"in a secure out-of-band way"; il tool SHOULD aggiungere header al file della chiave privata
per evitare divulgazioni accidentali.

**Cosa impedisce davvero (community docs):** senza la credenziale il client non puo' decifrare
il descriptor e quindi non apprende gli introduction point: non puo' nemmeno iniziare
l'handshake (https://community.torproject.org/onion-services/advanced/client-auth/).
E' autenticazione + discovery privata, NON rate limiting ne' revoca istantanea.

**Distribuzione chiavi:** operativa manuale — script (bash/rust/python) o openssl x25519 +
base32, poi copia out-of-band del `.auth_private` al client
(https://community.torproject.org/onion-services/advanced/client-auth/ — Step 1-4).
Tor Browser accetta anche l'inserimento della chiave via UI senza editare torrc (stessa pagina).

**Limiti pratici:**
- un file per client, una sola riga per file; file malformati ignorati (stessa pagina, Step 4);
- revoca = cancellare il `.auth` + **restart di tor** ("revocation will be in effect only after
  the tor process gets restarted", stessa pagina, Important);
- chiave perduta lato client = rigenerare coppia, riconsegnare, restart; nessuna procedura
  di recovery in-spec;
- nessun comando control-port lato servizio per aggiungere/rimuovere credenziali dinamicamente
  (discussione tor-dev: "no control port command for adding service-side client auth",
  https://lists.torproject.org/mailman3/hyperkitty/list/tor-dev@lists.torproject.org/thread/VJYSB5U2F5ZSOPZN7N5L5H4BXMDSEWFD/);
  la spec prevede `ADD_ONION_CLIENT_AUTH` ma marcata `[XXX figure out control port command format]`
  = non implementata (rend-spec Appendix G.2.1).
- Nota storica: la vecchia risposta "due keypair x25519+ed25519 / firma INTRODUCE1" si riferisce
  a thread tor-dev 2019 pre-implementazione; l'implementato (spec + docs attuali) usa solo
  `descriptor:x25519`.

## 2. Proof-of-Work defense

**Cos'e':** difesa DoS che priorizza, sotto carico, i client che risolvono un client-puzzle
(Equi-X/HashX di tevador); "prioritize verified effort (but not a way to verify users)"
(https://onionservices.torproject.org/technology/security/pow/ — What is PoW).
Il servizio parte da suggested-effort 0 (difesa dormiente) e lo alza dinamicamente sotto carico;
a effort 0 il puzzle e' bypassabile (stessa FAQ, Overview).

**Configurazione (direttive torrc reali, per-service):**
`HiddenServicePoWDefensesEnabled 0|1`, `HiddenServicePoWQueueRate` (default 250 req/s, 0 = illimitato),
`HiddenServicePoWQueueBurst` (default 2500, deve essere >= rate)
(https://community.torproject.org/onion-services/advanced/dos/ — sezione PoW).
Opzione globale: `CompiledProofOfWorkHash` (stessa pagina).
Esempio minimo: `HiddenServicePoWDefensesEnabled 1` accanto a HiddenServiceDir/Port.

**Versione minima:** disponibile da C Tor **0.4.8.1-alpha** in poi, abilitata di default
se compilato con modulo pow (stessa pagina: `tor --list-modules` deve mostrare `pow: yes`);
le librerie puzzle v1 (Equi-X/HashX, LGPL-3.0) richiedono build `--enable-gpl`
(verifica con `tor --version` che citi GPL — stessa pagina).
Lato client serve tor aggiornato (>= 0.4.8.1-alpha); i client Arti non la supportavano
(ad agosto 2023 "still under development", FAQ — Usability).

**Costo per il client legittimo:** normalmente zero (effort 0, connessione invariata);
sotto attacco, CPU/RAM single-thread per risolvere Equi-X; su arch 64-bit (hashx compilato)
veloce (~0.5s per puzzle tipico), su implementazioni interpretate 10-40x piu' lento
(minuti nei casi peggiori → timeout) — penalizza i device low-end (FAQ — Minimum device
requirements). Il client NON deve configurare nulla: risolve in automatico (FAQ — When and how
should a user enable PoW). Difesa dinamica: descriptor porta `pow-params v1 <seed-b64>
<suggested-effort> <expiration-time>`; seed ruotato anti-replay (FAQ — Descriptor fields).

**Quando conviene:** sempre per un servizio pubblico sotto minaccia di introduction flooding;
dormiente a costo ~0 quando non sotto attacco (FAQ + thread forum tor "operators please enable
tor PoW defense", https://forum.torproject.org/t/tor-relays-onion-services-operators-please-enable-tor-pow-defense/13043).
Limite noto: non copre flash-crowd legittime ne' attaccanti enormi ("low-to-mid-effort attacks",
FAQ — Is this feature equally effective); esiste attacco documentato di inflation
dell'effort ("OnionFlation") ma gli esperti raccomandano comunque di tenerla attiva
(fonte secondaria — dichiarata tale — https://sudoall.com/onionflation-tor-onion-services/).

## 3. Rate limiting senza IP

**Fatto base:** il backend vede solo la connessione locale da tor (tipicamente 127.0.0.1);
l'IP del client non esiste per design, quindi nessun rate limit per IP
(https://onionservices.torproject.org/technology/security/pow/ — Why is PoW needed:
"there's no way to apply traditional techniques of IP-based rate limits").

**Difese documentate a livello Tor (torrc), tutte senza IP:**
- Intro-point: `HiddenServiceEnableIntroDoSDefense 0|1`,
  `HiddenServiceEnableIntroDoSBurstPerSec`, `HiddenServiceEnableIntroDoSRatePerSec`
  (0 = infinito = di fatto disabilita) — rate limiting delegato agli intro point
  (https://community.torproject.org/onion-services/advanced/dos/ — Rate limiting at the
  Introduction Points; dos-spec https://spec.torproject.org/dos-spec/overview.html).
- PoW queue (sez. 2): priorizza per effort, drena a rate/burst configurati.
- Stream limits sul rendezvous circuit: `HiddenServiceMaxStreams` (max 65535, 0 = illimitato),
  `HiddenServiceMaxStreamsCloseCircuit 0|1` (1 = abbatte il circuito che eccede)
  (https://community.torproject.org/onion-services/advanced/dos/ — Stream limits).

**L'applicazione puo' distinguere i circuiti? Si', esplicitamente:**
`HiddenServiceExportCircuitID` (opzione torrc: `haproxy` o `isolate` pattern) esporta
l'ID circuito verso il backend in modo che l'app applichi euristiche proprie e "kill them"
(https://community.torproject.org/onion-services/advanced/dos/ — Webserver rate limiting:
"try to detect that overuse and kill them using the HiddenServiceExportCircuitID torrc option").
Quindi: rate limit per-circuito e' possibile SOLO via questa opzione + control-port
(chiusura circuito); senza, l'app vede solo connessioni indistinguibili da localhost.
Altre chiavi applicative documentate: token/sessione/cookie per utente logico,Captcha/test-cookie
front-end, header User-Agent/Referer come segnale debole (stessa pagina — Captchas and cookies).
[Opinione: i segnali header sono trivialmente spoofabili; valgono solo come telemetria.]

## 4. Pairing di Briar Mailbox

Fonte primaria: `API.md` del repo briar-mailbox
(https://code.briarproject.org/briar/briar-mailbox/-/raw/main/API.md; mirror
https://github.com/briar/briar-mailbox).

- **Forma del token:**Bearer HTTP `Authorization: Bearer <64 hex chars>` = 32 byte random
  (fonte secondaria — dichiarata tale — report web su `RandomIdManager.getNewRandomId()`,
  file `mailbox-core/.../system/RandomIdManager.kt`; non ho clonato il sorgente, da verificare
  contro il .kt se serve la riga esatta).
- **Chi lo genera:** la mailbox genera il setup token all'inizializzazione e lo mostra
  come QR code; l'owner lo consuma con `PUT /setup` (API.md — Setup/Pairing).
  I token per-contatto (`token`, `inboxId`, `outboxId`, 32 byte hex) li genera invece
  **Briar (il client owner)** e li invia con `POST /contacts` (API.md — Add a contact).
- **Prova del possesso:** presentazione del bearer su TLS/Tor; `PUT /setup` con setup token
  valido → `201 Created` + `{token: <owner token a lungo termine>, serverSupports: [...]}`;
  token gia' usato → `401 Unauthorized` (API.md).
- **Revoca:** nessun endpoint di revoca per singolo token; solo **remote wipe**
  `DELETE /` (owner) che resetta allo stato post-install (cancella tutti i file/token),
  oppure `DELETE /contacts/$id` per rimuovere un contatto intero (API.md — Contact Management).
  Crash di Briar tra `PUT /setup` e ricezione risposta = wipe + ricomincia (API.md).
- Ruoli: `SetupPrincipal` (single-use) → `OwnerPrincipal` (lungo termine) →
  `ContactPrincipal` (per-contatto); lookup contatto→owner→setup
  (fonte secondaria — DeepWiki briar-mailbox auth page; da confermare su `AuthManager.kt`).

## 5. Abusi noti contro depositi anonimi e contromisure

- **Introduction/rendezvous flooding (amplificazione CPU):** costruire rendezvous costa molto
  piu' al servizio/rete che all'attaccante → contromisure: PoW + intro-DoS rate/burst +
  scaling orizzontale Onionbalance
  (https://community.torproject.org/onion-services/advanced/dos/; FAQ — Why is PoW needed).
- **Aggressive circuits / troppe query per circuito:** `HiddenServiceMaxStreams(CloseCircuit)`
  + kill dei circuiti abusivi via `HiddenServiceExportCircuitID` + rate limiting del webserver
  (stessa pagina DoS).
- **Storage gratuito / riempimento disco:** la pagina DoS ufficiale NON copre quote disco —
  [inferenza] va risolto a livello applicativo: il modello Briar lo mostra in pratica:
  token capability per folder (`inboxId/outboxId`), upload consentito solo alla folder
  autorizzata dal token, altrimenti `404` (API.md — File Management); quote/TTL/signed-contract
  sono decisioni applicative, non di Tor.
- **Flash-crowd legittima:** PoW la gestisce solo degradando (timeout dei low-effort),
  non aumentando capacita' → serve Onionbalance + caching
  (FAQ — Does this feature solve all DoS; pagina DoS — Onionbalance, Caching).
- **Compartimentazione utenti fidati/non fidati:** onion dedicata + client-auth per i fidati,
  indirizzi separati per gli altri; troppi onion = piu' guard = peggio per la sicurezza,
  preferire client-auth (pagina DoS — Client authorization...).

## Applicabilita' a un Relay Prysm in Dart

**Dipende da Tor (torrc / versione / ops) — adottare cosi' com'e':**
- PoW: `HiddenServicePoWDefensesEnabled 1` (+ tuning Rate/Burst, default 250/2500);
  richiede C Tor >= 0.4.8.1-alpha con modulo `pow` e build GPL; costo zero a riposo.
- Intro-DoS: `HiddenServiceEnableIntroDoSDefense 1` + Rate/BurstPerSec commisurati.
- Stream cap: `HiddenServiceMaxStreams` + `...CloseCircuit 1`.
- Export circuito: `HiddenServiceExportCircuitID` per rate limit per-circuito lato app.
- Client-auth v3 come opzione di hardening per relay privati (un relay per utente fidato):
  file `.auth` + restart per revoca; distribuzione chiavi out-of-band (in Prysm: dentro
  il canale 1:1 gia' autenticato).
- Onionbalance/caching: non rilevanti per relay personale a basso traffico
  [opinione]; rilevano solo se relay condiviso ad alto traffico.

**Dipende dal protocollo applicativo (Dart) — da disegnare noi:**
- Contratto firmato di deposito (autorizzazione per envelope: chi puo' scrivere per chi,
  quanto, fino a quando) — Tor non lo fa.
- Capability token stile Briar (bearer 256-bit per folder/contratto, single-use setup token
  via QR/canale sicuro, owner token a lungo termine, revoca = wipe/rotazione) — Tor non lo fa.
- Quote disco, TTL, limiti dimensione/numero envelope, code a priorita' per effort applicativo.
- Rate limit per identita' applicativa (senderId del contratto), non per circuito:
  il circuito cambia, l'identita' resta.
- Autenticazione client a livello HTTP/app (bearer del contratto) INDIPENDENTE dalla
  client-auth di Tor: la prima autorizza l'operazione, la seconda nasconde il descriptor.

## Cosa NON funziona qui (non riproporre)

- **Qualunque difesa basata su IP** (ban, throttle per IP, allowlist IP, fail2ban):
  l'app vede solo localhost; la FAQ PoW lo dichiara esplicitamente.
- **Geolocalizzazione / reputazione di rete / ASN / blocklist IP:** stesso motivo, nessun
  segnale disponibile.
- **CAPTCHA di terze parti (reCAPTCHA & co.):** la pagina DoS ufficiale cita captcha
  self-hosted/test-cookie come opzione web generica, ma per un relay Dart headless che parla
  a client noti via contratto firmato e' fuori modello: introduce dipendenza esterna,
  deanonimizza (telefonate a Google), non automatizzabile dal client Tor-only
  [opinione — la citazione ufficiale esiste ma l'inapplicabilita' e' nostra].
- **TLS con CA / pinning DNS:** non esiste DNS ne' CA per .onion; l'autenticita' e'
  nella chiave .onion + client-auth, non in un certificato.
- **PoW come autenticazione:** PoW prova effort, non identita' ("not a way to verify users",
  FAQ); non sostituisce contratto firmato/token.
- **Client-auth come rate limiter o revoca istantanea:** nasconde il servizio ma non limita
  il tasso e richiede restart per revocare.
- **"Basta Onionbalance" per abusi di storage:** scala la disponibilita', non impedisce a un
  autorizzato di riempire il disco — servono quote/TTL applicative.
