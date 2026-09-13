# Lab a tre nodi per il live app testing del Relay

Type: task
Status: resolved

## Question

Lavoro manuale che sblocca tutte le prove dal vivo: oggi il lab sa fare **due** peer, per il Relay
servono **tre** nodi (client A, client B, Relay), tutti su Tor reale.

Da fare:

1. Verificare che il lab a due peer funzioni ancora su questo checkout: `prysmlab doctor`,
   `prysmlab up`, e il secondo container con
   `PRYSMLAB_CONTAINER=prysm-lab-b PRYSMLAB_HOST_LAB=/tmp/prysm-lab-b PRYSMLAB_VOLUME=prysm-lab-b-pub`
   (regola 17 della skill `live-app-testing`).
2. Registrare la **baseline** da cui misureremo il Relay: consegna diretta A->B con entrambi online, e
   drain della coda quando B era offline (la skill riporta ~8-11 s dopo il ritorno: confermare o
   correggere il numero su questa macchina).
3. Predisporre il **terzo nodo**: un container con il suo Tor e il suo hidden service, che oggi non
   ospita ancora un Relay (non esiste) ma dimostra il percorso: onion raggiungibile dai due client,
   un endpoint HTTP di prova che risponde attraverso Tor dalla rete reale.
4. Scrivere i comandi esatti in `.scratch/relay/lab.md`, cosi' che ogni sessione successiva non debba
   riscoprirli.

## Context

- `tool/live/prysmlab`, skill `.agents/skills/live-app-testing/SKILL.md`. Tutte le risorse host sono
  sovrascrivibili da env (`PRYSMLAB_VOLUME`, `tool/live/prysmlab:148`), ed e' questo che rende
  possibile un terzo nodo.
- Canali disponibili verso l'app: widget tree (VM Service), `evaluate` in-app, e il server loopback
  (`prysmlab peer post|onion|public`). `POST /message` non autentica nessuno ma
  `_validateAddressedToLocal` esige `receiverId == onion locale`.
- Vincoli di sicurezza della skill: mai fuori dal container, mai l'identita' reale dell'utente, PIN
  usa-e-getta, `down --purge` sempre.

## Done when

- I tre nodi vivono insieme e l'onion del terzo e' stampato e raggiungibile dai due client.
- Baseline misurata e scritta (consegna diretta, drain dopo offline).
- `.scratch/relay/lab.md` contiene la sequenza di comandi riproducibile, inclusa la teardown.
- Se qualcosa nell'ambiente non e' disponibile (docker, KVM), il ticket riporta cosa manca e la
  checklist precisa per l'umano, invece di fingere che funzioni.

## Answer

### 1. Preflight (`doctor`)

Prima run: `ok docker usable`, **FAIL `image prysm-lab present`** (exit 1).
Trappola: l'immagine presente era `prysm-l3e2e:latest` (5.62 GB, base Flutter)
che NON contiene il lab (`/opt/lab` assente) — `doctor` vuole `prysm-lab`.
Risolto con `tool/live/prysmlab build-image` (tutto cached, ~2 s), poi
`doctor` exit 0: docker 29.7.2 ok, rsync ok, repo tor binary ok, nessun tor
host, porta 12345 libera. Docker/KVM presenti: niente checklist per l'umano.

### 2. Due peer su HomeScreen

- `prysmlab up --timeout 1500` → container `prysm-lab` up in 36.8 s
  (staging + compile prima run), `onboard --pin 112233` → HomeScreen in 21.8 s.
- Lab B con gli env del ticket → container `prysm-lab-b` up in 34.9 s,
  onboard in 21.7 s, HomeScreen confermato via `screen`.
- Onion: A `x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion`,
  B `y2smgkwc3vos5vlx5jencmhvyr5z3ufqyzrscfzgkhdlwx26gum3asad.onion`
  (`peer onion`; base58 di B via `txlab onion b`, di A ricalcolato col codec
  di `txlab:198-211`).
- Pairing reciproco via dialogo Add contact (entrambi online): A→B ~90-120 s
  (bracketing largo, prima fetch di descriptor), B→A ~5 s
  (1789205975→1789205980, conferma i 5.5-7.9 s della skill).

### 3. Baseline misurata (orologi host, `date +%s`, polling eval Text+RichText)

- Diretta A→B, entrambi online: MARK2 inviato 1789206374 → reso su B
  1789206387 = **12-13 s**; MARK3 inviato 1789206393 → reso 1789206397 =
  **4 s**; MARK1 consegnato e reso su entrambi (bracketing largo per il
  trabocchetto `wait`, vedi sotto). Più lento del mediano della skill
  (0.43 s wire / 1.47 s render): qui c'era un restart di A con re-handshake
  WS e flap di presence. n=2 stretti + 1 largo: ordini di grandezza, non mediane.
- Drain: B spento (pkill dell'app nel container; osservato: muore anche il
  suo tor → peer del tutto offline, identità salva nel layer scrivibile),
  3 messaggi inviati da A (1789206426/31/35, accodati: 3 bubble su A),
  `restart` + `onboard` di B → **3/3 resi entro 1789206466, ≤9 s dopo la
  HomeScreen** (25 s dal `restart`, boot+tor+onboard inclusi).
  **Conferma gli 8-11 s della skill.**

### 4. Terzo nodo

Container `prysm-lab-relay` (ubuntu:24.04 + tor/curl/python3 da apt), torrc
con `HiddenServicePort 80 127.0.0.1:8080` su `python3 -m http.server`,
endpoint `/index.txt` = `prysm-relay-probe-ok`.
Onion: `k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion`
(chiavi effimere, distrutte al teardown — nessun valore privacy residuo).
Prova del percorso, via il SOCKS del tor DELL'APP nei client:
`docker exec prysm-lab curl --socks5-hostname 127.0.0.1:9050 http://<onion>/index.txt`
→ `prysm-relay-probe-ok` in **4 s**; da `prysm-lab-b` → ok in **8 s**.
(Prima fetch/self-test 112 s: propagazione descriptor, non un bug.)
I tre nodi sono stati vivi insieme (A, B, relay) con le fetch riuscite da entrambi.

### 5. Runbook e teardown

- `.scratch/relay/lab.md` scritto: comandi esatti, env, onion/ID, misurazione,
  9 trabocchetti (tra cui: `type` senza `-n` scrive nella ricerca; le bubble
  sono RichText e `wait`/`count` sono ciechi; tor-relay come root richiede
  dir root-owned; `restart` di B uccide anche il suo tor; `app.log` ha solo
  lo startup).
- Teardown eseguita: `down --purge` su entrambi i lab (container, volumi
  `prysm-lab-*-pub`, staging, immagine rimossi, verifiche ok) +
  `docker stop/rm prysm-lab-relay`. Verifica: nessun container `prysm-lab*`
  vivo, nessun volume, nessuno staging; restano solo i servizi preesistenti
  dell'utente (open_notebook, navidrome, downtify, nextcloud).
- Sicurezza skill rispettata: tutto nel container, PIN usa-e-getta 112233,
  identità effimere distrutte, repo mai scritto (le modifiche `lib/` in
  `git status` sono del sibling PlaceholderCleanup, non mie).

### Decisioni e aperti

- `txlab send` NON usato: si aspetta il peer `a=prysm-lab-a`, il nostro A è
  il default `prysm-lab` — baseline fatta a mano (consentito dal ticket) con
  polling eval equivalente al suo `wait_for_render`.
- B spento = app+tor morti (alternativa "solo app" documentata in lab.md §6,
  non realizzata): il numero di drain include il bootstrap tor del peer che ritorna.
- Resta aperto (fuori scope): rendere `txlab` consapevole del peer default
  oppure documentare il peer `a` nel runbook quando serviranno misure automatiche.
