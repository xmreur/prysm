# Relay — problemi e soluzioni della via ottimizzata

Documento di lavoro dell'effort RelayCreate (`.scratch/relay-create/map.md`). Elenca ogni
problema concreto del percorso attuale di creazione di un Relay e la soluzione decisa, con
codice o comandi pronti dove esistono. Non è ancora eseguito: è il piano di build che
segue le decisioni già prese in mappa.

Lingua: questo documento in italiano; codice, file, identificatori e commit in inglese.

Fatti misurati su cui poggia (2026-09-13):

- `.github/workflows/ci.yml`: un solo job `analyze-and-test`, Flutter pinnato `3.44.8`; i
  due package relay girano dentro il job Flutter col `dart` bundled; nessun path filter;
  nessun workflow di release per il relay; il vincolo "server mai dipendenza dell'app" è
  solo un commento (righe 42-43).
- `packages/prysm_relay_server`: ~3.900 righe Dart + ~1.800 di test (47 server, 26
  protocollo); dipende dal protocollo via `path: ../prysm_relay_protocol`; 0 import
  nell'app (`lib/`, `test/`).
- `tool/create_relay.sh`: 562 righe; compila ogni volta (`dart compile exe`), `docker run
  ubuntu:24.04` + `apt install tor` + `docker cp` del binario; `PERSIST=0` di default.
- Binario standalone 7,6 MiB; immagine `ubuntu:24.04` 117 MB; provisioning da cache
  ~15-18 s, re-run 4-11 s; primo `curl` all'onion 39,8 s contro budget app 30 s;
  propagazione del descriptor fino a ~2 min (picco osservato ~10 min).
- Nei 40 commit del branch `feat/relay-v1`, 0 toccano insieme `lib/` e il protocollo.
- Binario compilato oggi (Dart 3.13.2, x64): 8.022.736 byte, **dinamicamente linkato a
  glibc** (`ldd`: libc, libm, libdl, libpthread) — non è statico, quindi niente
  Alpine/musl senza `gcompat`; `serve` a riposo: **VmRSS 9,9 MB, 5 thread** (misurato
  4 s dopo `listening on`, data dir vuota).
- `dart compile exe` (SDK 3.13.2) accetta `--target-os` linux/macos/windows/android e
  `--target-arch` arm (armv7), arm64, x64, riscv64, ia32, riscv32. Cross-compilazione
  supportata verso Linux da qualunque host; macOS e Windows si compilano sul runner
  nativo.
- Il codice server non dipende da Linux salvo `restrictPath` (shell-out a `chmod`,
  saltato su Windows) e i `pgrep`/`pkill` dello script bash. Scritture su disco solo su
  evento (deposit, ack, pair, put/delete mailbox): lo sweeper dei 60 s scansiona gli item
  in memoria e rilegge solo `tokens.json`; riscrive solo se ha eliminato qualcosa.

Decisioni della mappa che questo piano esegue: immagine unica policy-driven; percorso
primario nativo systemd senza Docker, container come fallback; persistenza attiva di
default; pairing via QR **e** deep-link (ticket prototype ancora aperto). Nessuna delle
soluzioni richiede un repository separato: l'analisi dello split (monorepo vs split
totale vs split solo server) ha dato guadagno esclusivo nullo finché il relay ha un solo
sviluppatore.

---

## 1. Ogni push del relay paga il job Flutter completo

**Problema.** `flutter-action` + `apt` + `flutter pub get` + `flutter test` (1272 test)
anche per una riga cambiata in `store.dart`. Inoltre la CI non rispetta la regola
dell'handoff "test di race almeno 3 volte".

**Soluzione.** Job separato, Dart puro, con path filter. Nuovo file
`.github/workflows/relay.yml`:

```yaml
name: Relay
on:
  push:
    branches: [main]
    paths: ['packages/prysm_relay_protocol/**', 'packages/prysm_relay_server/**']
  pull_request:
    paths: ['packages/prysm_relay_protocol/**', 'packages/prysm_relay_server/**']
permissions: { contents: read }
jobs:
  relay:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: "3.9.0" }           # stesso SDK del pin Flutter 3.44.8
      - run: dart pub get && dart analyze && dart test
        working-directory: packages/prysm_relay_protocol
      - run: dart pub get && dart analyze && for i in 1 2 3; do dart test; done
        working-directory: packages/prysm_relay_server
```

In `ci.yml` i due step `dart pub get && dart analyze` restano (l'app importa il
protocollo e `flutter analyze` cammina i `test/` dei package: commento righe 37-45), ma
il `dart test` del server si toglie da lì, coperto da `relay.yml`.

Costo: 30 min. Richiede split: no.

## 2. Nessuna release del server: il binario nasce sulla macchina dell'operatore

**Problema.** `create_relay.sh` compila ogni volta; serve il Dart SDK sull'host; nessun
artefatto versionato; nessuna immagine pubblicata.

**Soluzione.** Workflow `.github/workflows/relay-release.yml` su tag `relay-v*`
(namespace separato dai tag dell'app). Due job: binari nativi x64/arm64 con checksum e
attestazione; immagine multi-arch su GHCR con provenance e SBOM (tutto gratis, keyless,
come da findings `.scratch/relay-create/research/06-pubblicazione-aggiornamenti.md`).

```yaml
name: Relay release
on: { push: { tags: ['relay-v*'] } }
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write
jobs:
  binaries:
    runs-on: ubuntu-latest
    strategy: { matrix: { arch: [x64, arm64, arm] } }   # arm = armv7 (Pi 32-bit)
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: "3.9.0" }
      - run: |
          dart pub get
          dart compile exe bin/prysm_relay.dart \
            --target-os=linux --target-arch=${{ matrix.arch }} \
            -o prysm-relay-${{ github.ref_name }}-linux-${{ matrix.arch }}
          sha256sum prysm-relay-* > SHA256SUMS-${{ matrix.arch }}
        working-directory: packages/prysm_relay_server
      - uses: actions/attest-build-provenance@v1
        with: { subject-path: 'packages/prysm_relay_server/prysm-relay-*' }
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            packages/prysm_relay_server/prysm-relay-*
            packages/prysm_relay_server/SHA256SUMS-*
            packages/prysm_relay_server/tool/install.sh
            packages/prysm_relay_server/tool/prysm-relay.service
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: packages
          file: packages/prysm_relay_server/Dockerfile
          platforms: linux/amd64,linux/arm64,linux/arm/v7
          push: true
          tags: |
            ghcr.io/xmreur/prysm-relay:${{ github.ref_name }}
            ghcr.io/xmreur/prysm-relay:latest
          provenance: mode=max
          sbom: true
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

Regole di tag (dai findings): `:relay-vX.Y.Z` immutabile per policy (aggiungere un check
"tag già esistente → fail" prima del push), `:latest` mobile solo per prove, pin per
digest nei runbook. Rebuild schedulato (`on: schedule`, settimanale) + Dependabot per
Docker per seguire le DSA di Tor senza lavoro manuale.

Costo: 2-3 h. Richiede split: no.

## 3. "Server mai dipendenza dell'app" è un commento, non un check

**Problema.** Righe 42-43 di `ci.yml` lo dichiarano; nessuno lo verifica. Un import
sbagliato e Flutter compila il server dentro l'app.

**Soluzione.** Uno step in `ci.yml`, prima di `flutter analyze`:

```yaml
- name: Relay server must never be an app dependency
  run: |
    ! grep -rq "prysm_relay_server" lib test pubspec.yaml
```

Costo: 5 min. Richiede split: no.

## 4. La ricetta del container vive in 562 righe di bash

**Problema.** `create_relay.sh` fa `docker run ubuntu:24.04` + `apt install tor` +
`docker cp` del binario ogni volta; niente Dockerfile, niente immagine riusabile.

**Soluzione.** `packages/prysm_relay_server/Dockerfile` multi-stage, base
`debian:trixie-slim` (Tor da Debian-security, come da findings). Il `COPY` del protocollo
richiede `context: packages` (vedi workflow del punto 2): è l'unico punto dove il path
dep si sente.

```dockerfile
# syntax=docker/dockerfile:1
# The build stage always runs on the builder's own arch and cross-compiles:
# no QEMU-emulated Dart SDK (10x slower), and dart:3.9 has no arm/v7 image anyway.
FROM --platform=$BUILDPLATFORM dart:3.9 AS build
ARG TARGETARCH TARGETVARIANT
WORKDIR /src
COPY prysm_relay_protocol /src/prysm_relay_protocol
COPY prysm_relay_server   /src/prysm_relay_server
WORKDIR /src/prysm_relay_server
RUN case "$TARGETARCH$TARGETVARIANT" in \
      amd64) DART_ARCH=x64 ;; arm64) DART_ARCH=arm64 ;; armv7) DART_ARCH=arm ;; \
      *) echo "unsupported $TARGETARCH$TARGETVARIANT" >&2; exit 1 ;; esac \
 && dart pub get \
 && dart compile exe bin/prysm_relay.dart \
      --target-os=linux --target-arch=$DART_ARCH -o /prysm-relay

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tor \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /prysm-relay /usr/local/bin/prysm-relay
COPY prysm_relay_server/tool/torrc         /etc/tor/torrc
COPY prysm_relay_server/tool/entrypoint.sh /entrypoint.sh
VOLUME ["/var/lib/prysm-relay", "/var/lib/tor/prysm-relay"]
ENTRYPOINT ["/entrypoint.sh"]
```

Base glibc obbligatoria (il binario Dart non è statico); `debian:trixie-slim` porta
anche `chmod`, che `restrictPath` invoca: un'immagine distroless lo perderebbe e `init`
fallirebbe rumorosamente. Solo lo stage finale è emulato via QEMU, e installa un
pacchetto: pochi secondi per arch.

`tool/entrypoint.sh` (~40 righe) esegue le quattro fasi oggi sparse nello script: `tor
--verify-config`, avvio Tor e attesa di `hostname`, `init` se manca `config.json`
(altrimenti riconciliazione `onion`/`port`/`admission` come oggi), `serve` in foreground.
`create_relay.sh` diventa un wrapper sottile di `docker run` con i due volumi sempre
montati; le domande interattive restano, i commenti descrittivi migrano in
`CREATE-RELAY.md`.

Costo: mezza giornata. Richiede split: no.

## 5. Persistenza opt-in: `docker rm` uccide identità e onion

**Problema.** `PERSIST=0` è il default (`create_relay.sh:32`); con `--no-persist` i due
segreti irreplaceabili (`identity.json`, chiave del hidden service) stanno nel layer
scrivibile del container e muoiono con lui, invalidando ogni Contract firmato.

**Soluzione.** Decisione di mappa: salvataggio attivo di default.

- Script: `PERSIST=1`; `--no-persist` rinominato `--ephemeral` con warning esplicito che
  nomina le conseguenze (identità e onion persi, tutti i pari devono ri-accoppiare).
- Dockerfile: i due `VOLUME` fanno sì che anche un `docker run` a mano crei volumi
  anonimi invece di perdere tutto.
- Nativo: nell'unit systemd del README (`Run it as a service`) aggiungere
  `StateDirectory=prysm-relay` (systemd crea `/var/lib/prysm-relay` con owner e permessi
  giusti) accanto a `ReadWritePaths=`.
- Ritiro esplicito: la cancellazione totale resta un comando dichiarato (`docker volume
  rm …`, `systemctl disable --now` + `rm -rf`), documentato in `Decommission`.

Costo: 15 min. Richiede split: no.

## 6. Installazione nativa: solo un README, nessun installer

**Problema.** Sull'host dedicato (VPS/Raspberry) l'operatore copia i comandi dal README.
Il percorso nativo è quello primario deciso in mappa, ma non ha un artefatto.

**Soluzione.** `packages/prysm_relay_server/tool/install.sh` versionato e allegato alla
release (modello Caddy: tarball + `SHA256SUMS`, mai auto-update del demone), più
`tool/prysm-relay.service` = l'unit del README, anch'essa allegata.

```sh
#!/usr/bin/env sh
set -eu
VER="${1:?usage: install.sh relay-vX.Y.Z}"
case "$(uname -m)" in
  x86_64)  ARCH=x64 ;;
  aarch64) ARCH=arm64 ;;
  armv7l)  ARCH=arm ;;
  *) echo "unsupported CPU $(uname -m): Dart needs armv7+, arm64 or x86_64 (a Pi Zero W / Pi 1 cannot host a relay)" >&2; exit 1 ;;
esac
BASE="https://github.com/xmreur/prysm/releases/download/$VER"
BIN="prysm-relay-$VER-linux-$ARCH"
curl -fsSLO "$BASE/$BIN"
curl -fsSLO "$BASE/SHA256SUMS-$ARCH"
sha256sum -c --ignore-missing "SHA256SUMS-$ARCH"
install -m 0755 "$BIN" /usr/local/bin/prysm-relay
apt-get install -y tor
curl -fsSLO "$BASE/prysm-relay.service"
install -m 0644 prysm-relay.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now prysm-relay
```

Tor via `apt` di sistema (aggiornamenti di sicurezza da Debian). Il torrc dell'hidden
service resta quello del `Tor runbook` del README; `install.sh` lo scrive con heredoc e
lo valida con `tor --verify-config` prima di ricaricare Tor. `.deb` come asset di
release è un passo 2 facoltativo (nFPM sullo stesso binario), non in v1.

Costo: 1 h. Richiede split: no.

## 7. Pairing manuale: tre valori da copiare e timeout freddo

**Problema.** La summary dello script stampa onion, fingerprint e token; l'utente li
ricopia nella schermata Relay; il primo `Read relay info` verso un onion freddo impiega
39,8 s contro i 30 s di budget per tentativo e finisce in errore muto.

**Soluzione, come realizzata.** Link **e** QR, entrambi dal provisioning:

- `RelayPairingLink` in `packages/prysm_relay_protocol`:
  `prysm-relay://pair?onion=…&fpr=…&token=…`. **Nessun campo `exp`**: la scadenza la
  conosce il relay, una copia nel link potrebbe solo mentire.
- `prysm_relay pair-link` stampa le quattro righe (`onion:`, `fingerprint:`, `token:`,
  `link:`) e il QR in blocchi unicode, **generato in Dart** (`lib/src/qr_text.dart` su
  `package:qr`, tenuto sulla linea 3.x perché la 4.x alzerebbe il floor SDK a 3.11):
  niente `qrencode` da installare nell'immagine. Entrypoint, `install.sh` e
  `create_relay.sh` lo chiamano; su boot fresco riusa il token di `init` (`--token`),
  quindi se ne consuma sempre uno solo.
- App: incolla, auto-detect nel campo indirizzo, scansione (solo dove
  `QrPlatform.isScanSupported`) → riempie i campi e parte da sola il fetch. Il
  fingerprint del link è il **riferimento contro cui l'app confronta il manifest**:
  match → riga di conferma, mismatch → Pairing bloccato come firma invalida. **Niente
  intent-filter**: registrare lo scheme presso il sistema operativo è fuori scope, il
  link si incolla o si scansiona.
- Timeout freddo: **un** secondo tentativo automatico a 60 s (non due × 45) con testo
  esplicito; un relay che risponde con un errore non viene mai ritentato.

Costo reale: una sessione. Provato dal vivo (link applicato, retry osservato sul primo
onion freddo, pairing completato, mismatch e link malformato respinti) e con il QR
decodificato da uno scanner reale, byte-identico alla riga `link:`.

## 8. Ogni fatto del relay vive in quattro sedi

**Problema.** Quarta tornata CodeRabbit: un fatto corretto in tre sedi su quattro (spec,
README del server, `CREATE-RELAY.md`, commenti e `usage` dello script).

**Soluzione.** Con `create_relay.sh` ridotto a wrapper sottile (punto 4) i commenti
descrittivi migrano in `CREATE-RELAY.md`: le sedi scendono a tre. In ciascuna,
un'intestazione stile `writing-for-agents`: *"Fonte di verità: spec §N; questa pagina
rimanda, non ripete"*. Checklist di review: ogni commit che cambia un fatto del relay
elenca nel messaggio le sedi toccate.

Costo: 30 min. Richiede split: no.

---

## 9. Il relay è pensato solo per Linux x64/arm64 da container

**Problema.** Script, README e `create_relay.sh` presuppongono Docker + Linux; niente
per un operatore su macOS o Windows, niente per un Raspberry 32-bit, nessun test che
dimostri che il codice gira altrove. I `pgrep`/`pkill` dello script e il `chmod` di
`restrictPath` sono le uniche dipendenze da POSIX, ma nessuno le ha mai provate fuori.

**Soluzione.** Tre livelli di supporto, dichiarati e verificati in CI, nell'ordine in
cui costano.

*Livello 1 — Linux, tre architetture (primario).* Tarball `x64`, `arm64`, `arm` (armv7)
dalla matrice del punto 2 e immagine `amd64/arm64/arm/v7` dal Dockerfile del punto 4.
Copre VPS, Raspberry Pi 3/4/5 e Zero 2 W (64-bit), Pi 2/3 con OS 32-bit. **Non copre**
Pi Zero W / Pi 1 (armv6: Dart richiede armv7+). `install.sh` mappa `uname -m` →
`x86_64=x64`, `aarch64=arm64`, `armv7l=arm`, e rifiuta `armv6l` con messaggio chiaro.

*Livello 2 — macOS e Windows nativi (best effort).* Due job aggiuntivi nella release su
`macos-latest` e `windows-latest` (compilazione nativa obbligatoria: niente cross verso
questi OS). Per ciascuno:

- macOS: `tor` da Homebrew, unit `launchd` (`~/Library/LaunchAgents/…plist`, allegato
  alla release come `tool/prysm-relay.plist`); `restrictPath` funziona (`chmod` c'è).
- Windows: Tor Expert Bundle, servizio via `sc create prysm-relay binPath=…` o NSSM;
  `restrictPath` è un no-op documentato ("ACL are the operator's business") — il README
  deve dirlo esplicitamente nella sezione Windows; `FileLock` funziona (`LockFileEx`).
  Da verificare sul runner: `atomic_write_test` (rename su file esistente),
  `cli_init_test` e `token_store_test` (lanciano la CLI reale) — se passano, il livello
  è supportato; se no, il README dichiara "non supportato" con il test che fallisce.

*Livello 3 — Android/Termux, altre arch (riscv64).* Compilabile, non supportato: già
escluso come host di relay per motivi di prodotto (il telefono è giù proprio quando serve
lui). Nessun artefatto, nessuna riga di documentazione.

In `relay.yml` (punto 1) aggiungere una matrice `os: [ubuntu-latest, macos-latest,
windows-latest]` per `dart test` del server: i test di race ×3 restano solo su Linux.

Costo: 2-3 h (matrice CI + plist + sezione README). Richiede split: no.

## 10. Nessuna garanzia di efficienza su hardware poco potente

**Problema.** Il relay è destinato a Raspberry/VPS minimi, ma nessuno ha misurato cosa
consuma né dichiarato un minimo hardware. Le tre voci di costo su un Pi sono: RAM (Tor +
relay), scrittura su SD (wear-out) e CPU per la crittografia di Tor.

**Soluzione.** Un budget dichiarato, misurato, e tre regole nel codice/config.

*Budget misurato.* Relay `serve` a riposo: **9,9 MB RSS, 5 thread** (x64, Dart 3.13.2,
data dir vuota). L'indice in memoria cresce con gli indirizzi registrati (una `Map`
hex→fingerprint, ~100 byte per contatto: 10.000 contatti ≈ 1 MB) e con gli item
pendenti (metadata, non payload: il payload resta su disco e si legge solo al pickup).
Tor a riposo su Pi: ~30-60 MB [INFERENCE da deploy comuni; misurare sul Pi con
`systemd-cgtop`]. Totale sotto 100 MB: entra in un Pi Zero 2 W (512 MB) con margine.
Minimo hardware da scrivere nel README: armv7+ o arm64, 256 MB RAM liberi, SD classe
A1 o meglio SSD/USB per il data dir.

*Regola 1 — scrivere su disco solo su evento.* Già vero (fatti in testa): deposit = 1
file + `flush` + `rename`; ack = 1 delete; sweeper = solo lettura di `tokens.json` ogni
60 s, scrittura solo se ha eliminato. Da proteggere con un test: "un minuto di sweeper
senza scadenze non scrive nulla" (conta i file `.tmp` creati). Log a `stdout` →
journald, mai su file nel data dir (`serve.log` dello script attuale va rimosso).

*Regola 2 — limitare la heap del runtime.* Il binario AOT legge `DART_VM_OPTIONS`
dall'ambiente; nell'unit systemd e nell'entrypoint:
`Environment=DART_VM_OPTIONS=--old_gen_heap_size=64` (MB). Su un Pi impedisce al GC di
espandersi fino alla RAM fisica prima di raccogliere; con 10 MB a riposo il tetto è
largo. Da verificare che il flag sia accettato dall'eseguibile AOT del SDK corrente
(`prysm-relay --help` con la variabile impostata non deve stampare "unrecognized
flag").

*Regola 3 — Tor a basso costo.* Nel torrc per Private Relay: **niente**
`HiddenServicePoWDefensesEnabled` (la PoW costa CPU al servizio, è per i Public Relay
sotto attacco), sì `HiddenServiceEnableIntroDoSDefense 1` (economica),
`HiddenServiceMaxStreams 32`, `NumCPUs 1` sui single-core. Il README ha già il runbook:
aggiungere il profilo "low-power" accanto a quello "public hardening".

*Verifica.* Provisioning nativo (punto 6) su un Pi reale o su container `arm64`/`arm/v7`
emulato: `systemd-cgtop` a riposo e durante un deposito + pickup; numeri scritti nel
README (`Size the hardware`, nuova sezione accanto a `Size the quotas`).

Costo: 2 h + una prova su Pi. Richiede split: no.

## Riepilogo

| # | Problema | Soluzione | Costo | Split? |
|---|---|---|---|---|
| 1 | CI Flutter per ogni push relay | `relay.yml` con path filter + race ×3 | 30 min | no |
| 2 | Nessuna release del server | `relay-release.yml`: tarball x64/arm64/armv7 + GHCR multi-arch + attestazioni | 2-3 h | no |
| 3 | Vincolo dep solo commentato | grep che fallisce il job | 5 min | no |
| 4 | Ricetta container in bash | Dockerfile multi-stage cross-compile + `entrypoint.sh`, script → wrapper | mezza giornata | no |
| 5 | Persistenza opt-in | `PERSIST=1`, `VOLUME`, `StateDirectory=` | 15 min | no |
| 6 | Nativo senza installer | `install.sh` + unit allegati alla release | 1 h | no |
| 7 | Pairing manuale | URI + QR + intent-filter + retry freddo | prototype, poi ~1 giorno | no |
| 8 | Quattro sedi per ogni fatto | script sottile → tre sedi, intestazioni fonte-di-verità | 30 min | no |
| 9 | Solo Linux x64/arm64 da container | tre livelli di supporto: Linux ×3 arch, macOS/Windows best effort in CI, resto escluso | 2-3 h | no |
| 10 | Nessuna garanzia su hardware povero | budget misurato (9,9 MB RSS), scritture solo su evento + test, `DART_VM_OPTIONS`, torrc low-power | 2 h + prova su Pi | no |

Ordine consigliato di esecuzione: 3 → 1 → 5 → 4 → 2 → 9 → 6 → 10 → 8 → 7. I punti 1-6,
8, 9 e 10 sono
server/packaging/CI e si verificano con `dart test` (×3) e una prova in container con
nome nuovo (mai il container `prysm-relay` vivo dell'utente); il punto 7 tocca il client
e si prova sull'app reale.

Prerequisito non tecnico: merge della PR #174 in `main` prima del primo tag `relay-v*`,
altrimenti la release punterebbe a un branch.
