# Pubblicazione e aggiornamenti: come spediscono gli altri — findings

Ticket: `.scratch/relay-create/issues/06-pubblicazione-aggiornamenti-come-spediscono-gli-altri.md`
Verifica fonti: 2026-09-13. Solo fatti, nessuna decisione.
Contesto repo (letto, non modificato): `packages/prysm_relay_server/README.md`
(binario standalone 7,6 MiB da `dart compile exe`, unit systemd documentata),
`tool/CREATE-RELAY.md` + `tool/create_relay.sh` (container `ubuntu:24.04` + `apt install tor`),
`.github/workflows/ci.yml` (solo `analyze-and-test` + CodeQL, nessuna pubblicazione).

Le 3 domande del ticket:

1. Registro e tag (GHCR/Docker Hub): tag immutabili vs `latest`, multi-arch,
   firma/attestazione (cosign/sigstore) e SBOM — cosa è standard a costo zero con GitHub Actions?
2. Distribuzione nativa senza Docker: tarball su Releases + checksum, mini-repo apt,
   o binario auto-aggiornante — cosa usano i progetti single-binary comparabili e cosa costa mantenerlo?
3. Coppia Tor + app custom: esempi di immagini che cuociono Tor di sistema con un binario sopra
   (base, dimensione, come seguono gli update di sicurezza di Tor)?

---

## 1. Registro e tag: GHCR / Docker Hub, multi-arch, attestazioni

### 1a. GHCR non ha tag immutabili a livello di registro

- GHCR supporta manifest Docker V2 e OCI; la doc ufficiale descrive `pull by digest`
  (`docker pull ghcr.io/NAMESPACE/IMAGE@sha256:<digest>`) come modo per fissare i byte esatti.
  Non esiste un interruttore "rendi i tag immutabili" come su ECR o GitLab.
  L'immutabilità si ottiene per processo: digest pin in produzione + CI che rifiuta
  di sovrascrivere i tag di release.
  Fonte: docs GitHub "Working with the Container registry" (sezioni Pull by digest / Pushing),
  verificata 2026-09-13:
  https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- Docker Hub invece ha introdotto gli **immutable tags** (beta, per-repository):
  `Settings → General → Tag mutability settings` con `All mutable` (default),
  `All immutable`, oppure `Specific tags are immutable` via regex (es. `^v\d+\.\d+\.\d+$`).
  Un push su un tag immutabile esistente fallisce; serve un nuovo tag.
  Fonte: docs Docker "Immutable tags on Docker Hub", verificata 2026-09-13:
  https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/
  (concetto digest: https://docs.docker.com/dhi/explore/security-concepts/digests/).

### 1b. Schema tag standard: sha + semver immutabile-per-policy + latest mobile

- Lo standard osservato (Docker `metadata-action` + `build-push-action`) è:
  `:<git-sha>` sempre unico, `:vX.Y.Z` (+ scorciatoie `:vX.Y`, `:vX`) per le release,
  `:latest` solo per dev/staging, mai nei manifest di produzione.
  `docker/metadata-action` genera questi tag da ref git / semver / sha:
  https://github.com/docker/metadata-action (verificata 2026-09-13).
- Poiché GHCR non blocca la sovrascrittura, i progetti seri aggiungono un check
  "no overwrite" in CI per i tag `v*` (API GHCR o `crane`/`regctl`: se il tag esiste,
  il workflow fallisce). In produzione si fa pin al digest
  (`image@sha256:…`, per multi-arch il digest della manifest-list/index).
  Fonte: docs Docker multi-platform builds, verificata 2026-09-13:
  https://docs.docker.com/build/building/multi-platform/

### 1c. Multi-arch a costo zero con buildx in Actions

- Pattern standard, gratis su runner pubblici:
  `docker/setup-qemu-action` + `docker/setup-buildx-action` + `docker/login-action`
  (GHCR con `GITHUB_TOKEN`) + `docker/build-push-action` con
  `platforms: linux/amd64,linux/arm64` (rilevante: VPS amd64 + Raspberry arm64).
  Produce una manifest-list OCI: un solo tag, il client tira la variante giusta.
  `cache-from/to: type=gha` per la cache layer. Fonte: README `docker/build-push-action`
  https://github.com/docker/build-push-action e docs multi-platform sopra,
  verificate 2026-09-13.

### 1d. Provenance + SBOM + cosign/Sigstore: gratis, keyless, in parte automatici

- `docker/build-push-action` v4+: **provenance automatica** (`mode=max` sui repo pubblici,
  `mode=min` sui privati; override con `provenance: mode=max`). **SBOM su richiesta**
  con `sbom: true`. Entrambe pushate al registry come attestazioni OCI (serve `push: true`,
  non funzionano con `load: true` / exporter `docker`). Attenzione documentata:
  la provenance `mode=max` include i valori dei build-args — mai passarci segreti.
  Fonte: docs Docker "Add SBOM and provenance attestations with GitHub Actions",
  verificata 2026-09-13:
  https://docs.docker.com/build/ci/github-actions/attestations/
- Azioni GitHub ufficiali (gratis, Sigstore keyless via OIDC, permessi
  `id-token: write` + `attestations: write`):
  `actions/attest-build-provenance` (provenance SLSA),
  `actions/attest-sbom` / `actions/attest` (SBOM SPDX/CycloneDX, es. generata con Syft),
  verificabili da chiunque con `cosign verify-attestation
  --certificate-oidc-issuer https://token.actions.githubusercontent.com …`.
  Fonti: https://github.com/actions/attest-build-provenance,
  https://github.com/actions/attest,
  https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations
  (indice how-to; guide con prerequisiti permessi/OIDC), verificate 2026-09-13.
- Costo: zero euro, solo righe di YAML. Nessun server di firma da gestire
  (istanza pubblica Sigstore per repo pubblici).

---

## 2. Distribuzione nativa senza Docker: cosa fanno i single-binary

### 2a. Il pattern dominante: tarball versionati su GitHub Releases + checksum

- **Caddy** (Go, single-binary, il comparabile più calzante): ogni release su
  `github.com/caddyserver/caddy/releases` contiene archivi per piattaforma
  (es. `caddy_2.11.4_linux_amd64.tar.gz`) + file `caddy_<versione>_checksums.txt`
  (SHA256). Flusso utente: `wget` tarball + checksum, `sha256sum -c`,
  `tar xzf`, `install -m 0755 caddy /usr/local/bin/`. Fonte: release Caddy
  (verificata 2026-09-13 via doc e mirror checksum `caddy_2.11.4_checksums.txt`).
- **SimpleX SMP/XFTP server** (Haskell ma stesso modello distributivo server):
  binari grezzi per release su GitHub (es. `smp-server-ubuntu-24_04-x86-64`)
  con SHA256 per asset; via Docker l'immagine è `simplexchat/smp-server:latest`
  o tag pinnato (`:v7.0.0`); update = `docker compose pull && docker compose up -d`,
  stato in volumi montati (`/etc/opt/simplex`, `/var/opt/simplex`).
  Fonti: DeepWiki "Server Deployment/Installation" per simplex-chat/simplex-chat e
  simplexmq + tracker release `simplex-chat/simplexmq` (v6.5.0–v7.0.0), verificate 2026-09-13.
- **Dart `compile exe`** (il nostro caso): `dart.dev/tools/dart-compile`
  documenta `--target-os=linux --target-arch=arm64|x64` (cross-compilazione verso
  Linux supportata; per altri OS si compila sul runner nativo). Il binario è
  self-contained, niente SDK sul target. Pattern CI osservato: matrice
  (`ubuntu-latest` → linux x64 + cross arm64; `dart-lang/setup-dart`;
  upload con `softprops/action-gh-release`), asset `prysm-relay-<ver>-linux-<arch>`
  + `SHA256SUMS`. Fonte: https://dart.dev/tools/dart-compile (verificata 2026-09-13).
  Il README del repo conferma l'ordine di grandezza: 7,6 MiB.
- Costo tarball+checksum: **minimo** — un workflow tag-triggered
  (build, sha256sum, `gh release create`), nessun server, nessuna chiave GPG da ruotare.

### 2b. `.deb` come asset di release (sì) vs mini-repo apt (quasi mai in proprio)

- **`.deb` come asset**: con GoReleaser + nFPM (o, per Dart, `nfpm`/`fpm` a mano
  sullo stesso tarball) si allega un `.deb`/`.rpm` alla release;
  l'utente fa `sudo apt install ./prysm-relay_*.deb`. Stesso job CI, costo quasi zero.
  Fonti: https://goreleaser.com/customization/package/nfpm/,
  https://nfpm.goreleaser.com/docs/ (verificate 2026-09-13).
- **Repo apt vero** (`apt install prysm-relay` da URL stabile): richiede hosting
  (Pages/S3/VM), metadati (`dists/<suite>/InRelease`, `Packages.gz` via
  `dpkg-scanpackages`/`apt-ftparchive`), chiave GPG con rotazione/scadenza,
  rigenerazione + rifirma a ogni versione. Chi lo fa senza inventare nulla usa un
  host esterno: **Caddy usa Cloudsmith** (`dl.cloudsmith.io/public/caddy/stable`,
  canali `stable`/`testing`, chiave GPG importata in
  `/usr/share/keyrings/caddy-*-archive-keyring.gpg`, pacchetto che porta anche
  unit systemd + Caddyfile). Alternativi a pagamento/gestione: Packagecloud,
  Gemfury. Fonti: guide installazione Caddy Cloudsmith (verificate 2026-09-13).
- Nessun comparabile serio gestisce un repo apt "a mano su VPS proprio" per un
  singolo binario: o asset `.deb` sciolto, o repo ospitato.

### 2c. Binario auto-aggiornante: i comparabili NON lo fanno

- Caddy, SimpleX, Caddy-like Go: nessun meccanismo di self-update nel server;
  aggiornano con `apt upgrade`, `wget` del tarball, o `compose pull`.
  L'auto-update in un demone di rete è un onere (firme, rollback, restart sicuro,
  canale update) che nessun progetto affine si accolla; anche gli helper
  (es. Tailscale, Caddy) delegano al package manager o a un reinstall.
  Chi vuole "un comando" pubblica uno script d'installazione versionato
  (`install.sh` che scarica tarball + verifica checksum), non un demone che si riscrive.
  [INFERENZA da assenza nei docs dei progetti citati, verificata 2026-09-13.]

---

## 3. Coppia Tor + app custom: basi, dimensioni, update di sicurezza

### 3a. Non esiste un'immagine ufficiale Tor Project; il pattern è "base slim + apt/apk tor + binario"

- Il Tor Project non pubblica un'immagine Docker ufficiale; esistono immagini
  community e il pattern fai-da-te è documentato ovunque allo stesso modo:
  `FROM debian:bookworm-slim` (o `trixie-slim`) + `apt-get install -y
  --no-install-recommends tor` + `rm -rf /var/lib/apt/lists/*`, oppure
  `FROM alpine:3.20` + `apk add --no-cache tor`; `tor -f /etc/tor/torrc` come CMD
  (foreground, come vuole Docker); hidden service via direttive `HiddenServiceDir /
  HiddenServicePort` nel torrc montato o cotto. Fonti: guide community Tor/Docker
  e `community.torproject.org/relay/setup/bridge/alpine/` (verificate 2026-09-13).
- Esempi concreti: `crasivo/tor-proxy`, `okunev/tor-proxy` (Debian-based, proxy
  SOCKS/DNS con torrc montato); `ghcr.io/techroy23/docker-tor-redsocks`
  (base trasparente Tor+iptables/redsocks da cui fare FROM).
  Riferimenti: https://hub.docker.com/r/crasivo/tor-proxy,
  https://hub.docker.com/r/okunev/tor-proxy,
  https://github.com/techroy23/Docker-Tor-Redsocks (verificati 2026-09-13).
- Nota per il nostro caso (da CREATE-RELAY.md, non da fonti esterne): lo script
  odierno installa Tor via apt dentro `ubuntu:24.04`. Passare la base a
  `debian:trixie-slim` è coerente con gli esempi e riduce la superficie;
  Alpine è più piccolo ma cambia user (`tor` vs `debian-tor`) e libc: **musl NON
  basta** — il binario `dart compile exe` è dinamicamente linkato a glibc (misurato
  2026-09-13 con `ldd`: libc, libm, libdl, libpthread), quindi Alpine richiederebbe
  `gcompat` o una base glibc. Corretta l'inferenza iniziale "binario statico".

### 3b. Dimensioni finali (ordini di grandezza)

- Base `debian:bookworm-slim` ~80 MB + pacchetto `tor` + dipendenze ~ decine di MB;
  binario relay ~7,6 MiB (misurato nel README). Totale atteso ~150–250 MB.
  Variante Alpine: base ~8 MB + `tor` apk ~ pochi MB + binario → totale ~50–100 MB.
  [INFERENZA da taglie pubbliche delle basi + misura README; da confermare nel
  ticket 02 con una build reale, non qui.]
- SimpleX pubblica sia binari grezzi sia immagini Docker sullo stesso codice:
  doppio canale senza doppio mantenimento (stesso job CI, due artifact).

### 3c. Update di sicurezza di Tor senza rebuild continui: non si scappa dal rebuild, ma lo si automatizza

- Fatti Debian (verificati 2026-09-13):
  - `tor` riceve fix via `*-security` con DSA (es. DSA-6260-1, DSA-6372,
    serie `0.4.9.x` su trixie/bookworm) e, quando serve una serie upstream nuova,
    via `trixie-backports` (`0.4.9.11-1~bpo13+1`, installazione esplicita
    `apt install tor/trixie-backports`). Tracker: https://security-tracker.debian.org/tracker/tor ;
    avvisi: https://www.debian.org/security/ .
  - Alternativa "sempre freschissimo": repo upstream `deb.torproject.org`
    (https://support.torproject.org/apt/ — redirect alla doc d'installazione,
    verificata 2026-09-13), a costo di una terza trust-anchor oltre Debian.
  - Avvertenza LTS: su bookworm in fase LTS `tor` è tra i pacchetti che potrebbero
    non ricevere più security update — altro motivo per basarsi su stable corrente
    (trixie) e non su oldstable.
- Fatti container: `apt upgrade` dentro un container long-lived è un anti-pattern;
  la via standard è **rebuild dell'immagine** (nuovo layer apt) + `pull`/`recreate`.
  Nessun esempio osservato fa "Tor che si aggiorna da solo dentro l'immagine":
  tutti ricostruiscono. L'automazione standard a costo zero è:
  pin della base per digest + **Dependabot updates per Docker** (apre PR a ogni
  nuova base) + **rebuild schedulato** (es. settimanale) + tag `:latest` mobile
  e release pinnate per digest. [INFERENZA operativa da docs Dependabot/Docker,
  prassi dei repo osservati; meccanismo da dettagliare nel ticket 02.]

---
## Tabella: opzioni → costo di mantenimento

| Opzione | Cosa comporta | Costo di mantenimento | Note |
|---|---|---|---|
| GHCR, tag `:vX.Y.Z` + `:latest` + digest pin, multi-arch buildx | YAML CI standard, check no-overwrite in CI | ~zero €, minuti/mese | `latest` mobile, release immutabili-per-policy; prod per digest |
| Provenance `mode=max` + SBOM `sbom:true` / `actions/attest-*` | flag/action in più, `id-token:write` | ~zero | keyless Sigstore, verifica con cosign |
| Docker Hub immutable-tags regex | click in Settings | ~zero | utile solo se si sceglie Docker Hub oltre/invece GHCR |
| Tarball `prysm-relay-<ver>-linux-<arch>` + `SHA256SUMS` su Releases | workflow su tag, cross-compile arm64 | basso, una tantum + minuti/release | canale primario nativo; copre VPS + Raspberry |
| `.deb`/`.rpm` come asset di release (nFPM/fpm) | estensione dello stesso job | basso | `apt install ./file.deb`, niente repo |
| Mini-repo apt self-hosted (Pages/S3 + GPG + InRelease) | hosting + chiavi + rifirme | **alto**, l'unico vero costo fisso | sconsigliato finché bastano tarball/.deb |
| Repo apt ospitato (Cloudsmith/Packagecloud, modello Caddy) | account esterno (+€ oltre quota free) | medio-basso, delegato | da valutare solo se `apt install prysm-relay` diventa requisito |
| Binario auto-aggiornante | update channel, firme, rollback | **alto + rischio** | nessun comparabile lo fa; non inventarlo |
| Immagine Tor+binario, rebuild su DSA/schedule | Dependabot + rebuild schedulato | basso | `apt upgrade` nel container: no; rebuild: sì |
| Repo Tor upstream `deb.torproject.org` nell'immagine | terza trust-anchor, pin apt | medio (tracking release Tor) | solo se Debian-security risulta troppo lento per le nostre minacce |

---
## Raccomandazione esplicita ma NON vincolante (per ticket 02 e 03)

- **Ticket 02 (immagine prebuilt):** GHCR come unico registro; build multi-arch
  `linux/amd64,linux/arm64` con `build-push-action`; tag `:vX.Y.Z` + `:latest`
  (mobile) + pin per digest nei doc/runbook; provenance `mode=max` + `sbom:true`
  (gratis); base `debian:trixie-slim` + `tor` da Debian-security (backports solo
  se una DSA lo richiede; non aggiungere `deb.torproject.org` in v1);
  rebuild schedulato + Dependabot per seguire le DSA senza lavoro manuale.
- **Ticket 03 (installazione nativa systemd):** canale primario = tarball
  versionati su GitHub Releases + `SHA256SUMS` (x64 + arm64 via
  `dart compile exe --target-os=linux --target-arch=`), con `install.sh`
  versionato che verifica il checksum; `.deb` come asset come passo 2 facoltativo;
  niente repo apt self-hosted e niente auto-update in v1 (come Caddy/SimpleX:
  `apt`/tarball/`compose pull`, mai self-update del demone).
- Entrambe le raccomandazioni sono **revocabili nei ticket 02/03**: se lì emergono
  vincoli diversi (es. requisito `apt install` da URL stabile), il repo ospitato
  esterno resta l'alternativa censita sopra.

---
## Fonti (tutte verificate 2026-09-13)

- GHCR / pull by digest / push: https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- Attestazioni artifact (indice how-to): https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations
- `actions/attest-build-provenance`: https://github.com/actions/attest-build-provenance
- `actions/attest`: https://github.com/actions/attest
- Docker attestazioni SBOM/provenance in Actions: https://docs.docker.com/build/ci/github-actions/attestations/
- Docker multi-platform builds: https://docs.docker.com/build/building/multi-platform/
- `docker/build-push-action`: https://github.com/docker/build-push-action
- `docker/metadata-action`: https://github.com/docker/metadata-action
- Docker Hub immutable tags: https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/
- Digest: https://docs.docker.com/dhi/explore/security-concepts/digests/
- Dart compile exe / cross-compile: https://dart.dev/tools/dart-compile
- `dart-lang/setup-dart`: https://github.com/dart-lang/setup-dart
- GoReleaser nFPM: https://goreleaser.com/customization/package/nfpm/ ; https://nfpm.goreleaser.com/docs/
- Caddy releases + checksum / install apt Cloudsmith: https://github.com/caddyserver/caddy/releases ; guide installazione Caddy (Cloudsmith `dl.cloudsmith.io/public/caddy/stable`)
- SimpleX server deploy/install: DeepWiki simplex-chat/simplex-chat "Server Deployment", simplexmq "Installation"; release tracker `simplex-chat/simplexmq` (v6.5.0–v7.0.0)
- Tor su Alpine (community): https://community.torproject.org/relay/setup/bridge/alpine/
- Immagini Tor community: https://hub.docker.com/r/crasivo/tor-proxy ; https://hub.docker.com/r/okunev/tor-proxy ; https://github.com/techroy23/Docker-Tor-Redsocks
- Debian security tracker tor: https://security-tracker.debian.org/tracker/tor ; avvisi: https://www.debian.org/security/
- Tor Project apt doc: https://support.torproject.org/apt/

