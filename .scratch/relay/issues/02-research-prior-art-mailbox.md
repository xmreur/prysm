# Prior art: mailbox store-and-forward nei messenger che non si fidano del server

Type: research

## Question

Come risolvono lo store-and-forward i sistemi che assumono il server ostile? Per ognuno di questi,
rispondere con fatti tracciati alla fonte primaria (spec, sorgente, RFC — non blog post):

- **Briar Mailbox** (il caso piu' vicino: Tor-only, mailbox per contatto, pairing via QR)
- **SimpleX** (SMP: queue unidirezionali, indirizzi separati per mittente e destinatario)
- **Signal** (sealed sender, server come deposito, delivery receipt)
- **XMPP** (MAM + CSI + push, con server semi-fidato)
- **Matrix** (homeserver: cosa vede, come si sincronizza)
- **Delta Chat / chatmail** (server ridotto al minimo, retention aggressiva)

Per ciascuno: (a) cosa vede il server di mittente/destinatario/tipo/dimensione/orario; (b) come
l'utente si autentica al deposito; (c) come si limita l'abuso; (d) retention e quote dichiarate;
(e) come avviene il ritiro (pull, push, long-poll); (f) come gestiscono il **primo contatto** quando
il destinatario e' offline; (g) quale errore noto hanno pagato (bug o critica pubblica documentata).

## Done when

- Findings in `.scratch/relay/research/02-prior-art-mailbox.md`, ogni claim con link alla fonte
  primaria e, dove esiste, al file/riga del sorgente.
- Una tabella comparativa sulle sei dimensioni (a)-(f).
- Una sezione finale "cosa importiamo in Prysm e cosa no", con almeno cinque lezioni concrete e per
  ciascuna il ticket della mappa che ne dipende.
- Nessuna raccomandazione travestita da fatto: le opinioni vanno marcate.

## Answer

Sintesi secca (dettagli e citazioni in `../research/02-prior-art-mailbox.md`):

- **Briar Mailbox**: vede ID contatti/file e dimensioni, contenuti cifrati; auth con bearer
  per-contatto dopo pairing QR single-use; antiabuso = solo contatti registrati; nessun TTL;
  ritiro pull via Tor; **primo contatto offline non gestito** (solo contatti esistenti);
  prezzo pagato: secondo device sempre acceso + rubrica in chiaro sul Mailbox.
- **SimpleX SMP**: il server vede solo ID effimeri di coda + blob (zero identità, blocchi da
  16 KiB); auth con firme effimere per-coda; antiabuso via BLOCKED/rate-limit/basic-auth;
  TTL ~21gg + quota 128/coda, ACK cancella; pull SUB/RECV/ACK + push NTF separato; **primo
  contatto = coda insicura + corsa KEY/SKEY (v9)**; prezzo: la corsa è accaparrabile.
- **Signal**: sealed sender nasconde il mittente (server vede solo destinatario + blob);
  sender-cert + delivery token da 96 bit; antiabuso = solo chi conosce la profile key;
  push ws + pull; primo contatto richiede numero + prekey, sealed solo dopo; prezzo: identità
  telefonica + oracolo centrale.
- **XMPP**: server vede tutto (from/to/type/stanze intere in MAM); SASL; retention a
  discrezione senza buchi; stream + MAM/RSM + CSI + push; primo contatto via subscription ma
  spam noto; prezzo: policy anti-server non negoziabili col server (OTR rimosso).
- **Matrix**: homeserver vede sender/room/tipo/ts/membership; access_token; storico permanente;
  long-poll /sync; primo contatto via invito + OTK claim su server fidato (non copiabile da noi);
  prezzo: metadati centralizzati + key-server fidato.
- **Delta chatmail**: vede header email + size; login IMAP; retention **20gg / 7gg (>200KB) /
  90gg inattivi**; pull IMAP; primo contatto sempre possibile (è email) + contact-request;
  prezzo: quote piene = account morto (issue relay#489).

Sei lezioni per Prysm: (1) mailbox-ID opachi stile SMP → Threat model e metadati; (2) secure
rapido anti-corsa per prekey → Primo contatto offline; (3) bearer setup→owner→deposito + 404
stile Briar → Auth e Pairing; (4) TTL ~20gg + delete al pickup → Retention/quote/overflow;
(5) delivery-token = contratto firmato, Relay cieco → Whitelist/blacklist; (6) solo pull,
hint best-effort → Semantica consegna/UI. Scartati: key-server fidato, archivio permanente,
oracolo centrale anti-spam.

Findings: [../research/02-prior-art-mailbox.md](../research/02-prior-art-mailbox.md)

Status: resolved
