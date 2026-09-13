# Installazione nativa systemd senza Docker su host dedicato

Type: grilling
Status: resolved

## Question

Decisione di impianto: sull'host dedicato (VPS/Raspberry, senza l'app) il boundary container anti-`pkill` non serve — promuovere a **percorso primario l'installazione nativa** (Tor di sistema + binario + torrc + unit systemd del README) e tenere il container come fallback?

Da decidere con grilling (HITL — tocca il modo in cui gli operatori vivono il relay):

1. Primario nativo vs primario container-prebuilt: quale installa l'operatore tipo (amico smanettone? utente VPS? tu su Raspberry?) e quale documentiamo per primo?
2. Chi possiede cosa: pacchettizzazione (tarball con binario + unit + torrc template?), `apt install tor` di sistema, `HiddenServiceDir` e `dataDir` con permessi 0700/0600, utente dedicato `prysm-relay`.
3. Upgrade e backup nativi: stop-replace-start del README basta, o servono timer systemd per backup dei due segreti (`identity.json` + chiave HS) e procedura di restore provata?
4. Cosa succede a `create_relay.sh`: resta il provisioning container per chi lo vuole, mentre il nativo è un secondo script/playbook — o un unico entrypoint con `--target native|container`?

## Context

- Baseline di [Misure del costo di creazione attuale](01-misure-costo-creazione-attuale.md): senza i suoi numeri, non si sa quanto il nativo risparmia davvero (niente pull 117 MB, niente apt-in-container, Tor di sistema già bootstrappato).
- `packages/prysm_relay_server/README.md`: sezioni `Run it as a service` (unit già pronta), `Back up and restore`, `Tor runbook` (validazione torrc + log obbligatori).
- Motivo del container: `lib/util/tor_service.dart:670` (`pkill -9 tor`) — assente sull'host dedicato, quindi il vincolo che imponeva il container lì decade; il vincolo "relay fuori dall'app" resta.
- Handoff vivo: container `prysm-relay` dell'utente intoccabile; prove con nomi nuovi.

## Done when

- Scelta primario (nativo vs container) con motivo legato al profilo operatore, scritta nella risoluzione.
- Forma del distributable nativo (tarball/script/unit) e proprietà di backup/restore/upgrade decise.
- Futuro di `create_relay.sh` (due percorsi vs entrypoint unico) deciso.

## Resolution

Deciso con l'utente: percorso primario = **installazione nativa senza Docker** (Tor di
sistema + binario + unit systemd), container come fallback. Distributable dai findings
research: tarball versionati su Releases + `SHA256SUMS` (x64 + arm64) + `install.sh`
versionato che verifica il checksum; `.deb` come passo-2 facoltativo. Niente repo apt
self-hosted, niente auto-update nel demone.
