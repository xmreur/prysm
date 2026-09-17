# RelayCreate — mappa

Label: `wayfinder:map`
Tracker: markdown locale (`.scratch/relay-create/`)
Ticket: `.scratch/relay-create/issues/NN-<slug>.md` — frontiera = file `Status: open`, senza `Blocked by` aperti

## Destination

Una via alternativa per **creare un Relay su host dedicato (VPS/Raspberry)** — dentro tutti i vincoli esistenti — che provisiona in secondi con immagine prebuilt + installazione nativa systemd + pairing a un click: la mappa è finita quando resta solo da eseguire, senza più nulla da decidere.

## Notes

**Dominio**: Prysm, messenger P2P Tor-only in Flutter/Dart; Relay store-and-forward `prysm-relay/1`. Glossario in `CONTEXT.md`; legge del wire in `.scratch/relay/proto/relay-protocol-v1.md`; funzionamento e threat model in `docs/RELAY.md`; percorso attuale in `packages/prysm_relay_server/tool/CREATE-RELAY.md` + `tool/create_relay.sh` (562 righe) + `packages/prysm_relay_server/README.md`.

**Wayfinder standard**: planning, non esecuzione — ogni ticket risolve una decisione; la mappa è finita quando la via è chiara e non resta che farla. Nessun ticket di build; i prototipi producono solo artefatti usa-e-getta linkati, mai codice nel branch.

**Skill da chiamare in ogni sessione**: `grilling` + `domain-modeling` (default per i ticket `grilling`), `prototype` per i ticket `prototype`, `research` per i ticket `research`, `ponytail` quando un ticket si gonfia, `context-saving` a fine sessione. `live-app-testing` solo se un ticket tocca il client Flutter (qui non previsto: il percorso è server/packaging/UX di pairing).

**Vincoli fissati dalle risposte dell'utente (non si rinegoziano senza ridisegnare la destinazione)**:

- Tutto insieme: velocità di provisioning + niente dipendenze pesanti + UX a un click, anche se tocca più pezzi.
- Host dedicato (VPS/Raspberry) senza l'app: il boundary container anti-`pkill` (`lib/util/tor_service.dart:670`) lì non serve — la via nativa è ammessa come primaria.
- Tutti i vincoli Relay restano: solo onion, Dart puro (`prysm_relay_protocol` + `prysm_relay_server`, zero Flutter), relay fuori dall'app, loopback-only, `prysm-relay/1` intatto, nessuna health/metrics endpoint pubblica.
- Lingua: mappa e ticket in italiano; codice, identificatori, spec e documentazione in inglese.

**Deviazione dal tracker** (ereditata dalla mappa Relay): i findings dei ticket `research` vanno in `.scratch/relay-create/research/NN-<slug>.md`, non su un branch `research/<name>`: un solo worktree, niente checkout concorrenti.

**Piano di build**: [problemi-e-soluzioni.md](problemi-e-soluzioni.md) — dieci problemi del percorso attuale con la soluzione concreta (codice/comandi), costo e ordine di esecuzione; esegue le decisioni qui sotto, non ne prende di nuove. **Stato 2026-09-13**: tutti e dieci i punti implementati e committati in locale (mai pushati). **La mappa è chiusa**: nessun ticket aperto, nessuna decisione pendente; la nebbia qui sotto è materiale per un effort futuro, non per questo.

## Decisions so far

<!-- una riga per ticket chiuso: gist + link. -->

- [Pubblicazione e aggiornamenti: come spediscono gli altri](issues/06-pubblicazione-aggiornamenti-come-spediscono-gli-altri.md): GHCR+digest-pin e tarball Releases+SHA256 censiti come canali, niente repo apt self-hosted né auto-update; fatti e raccomandazione non vincolante per immagine e systemd nei findings research.
- [Immagine prebuilt pubblicata vs compilazione ogni volta](issues/02-immagine-prebuilt-pubblicata.md): immagine unica policy-driven, GHCR + digest pin, base debian:trixie-slim (dettagli dai findings).
- [Installazione nativa systemd senza Docker su host dedicato](issues/03-installazione-nativa-systemd.md): nativo primario, container fallback; tarball + SHA256SUMS + install.sh.
- [Persistenza e identità di default](issues/04-persistenza-identita-default.md): salvataggio attivo di default, cancellazione solo con ritiro esplicito.
- [Pairing a un click dal provisioning](issues/05-pairing-un-click.md): link `prysm-relay://pair?onion=&fpr=&token=` + QR dal provisioning; l'app incolla/scansiona, riempie i campi e confronta da sola il fingerprint; retry automatico a 60 s sul primo onion freddo. Registrazione OS dello scheme fuori scope.

## Not yet specified

<!-- nebbia in scope: si vede che arriva, non è ancora abbastanza nitida per un ticket -->

- **Multiplexing N relay su un solo Tor**: un demone Tor, N hidden service, N `serve` su porte loopback diverse — quanto risparmia davvero su un host con più tenant.
- **Pool di onion pre-pubblicate**: chiavi HS generate e pubblicate in anticipo per azzerare l'attesa del descriptor al momento del bisogno; chi custodisce le chiavi e per quanto.
- **Monitoraggio host-side senza endpoint**: la spec vieta health non autenticata — cosa osserva l'operatore (solo `status`, `du`, log `counters`) e se basta un timer systemd che pagina.
- **Fleet di Public Relay**: ammissione, rotazione token e quota su più nodi con un solo operatore.
- **Upgrade senza downtime**: stop-replace-start documentato nel README — se serve di più (drain, rollback) e per chi.

## Out of scope

<!-- oltre la destinazione: chiuso, non gradua mai -->

- **Relay co-ospitato con l'app** — viola il vincolo fuori-dall'app e resuscita il `pkill -9 tor` che il container risolve.
- **Tor embedded non-Dart (es. Arti in-process)** — viola il vincolo Dart puro.
- **Relay in clearnet, non-Tor** — mai (già fuori scope della mappa Relay).
- **Health/metrics endpoint pubblica non autenticata** — vietata dal design (`/relay/manifest` resta l'unica pubblica).
- **Federazione Relay↔Relay, relay a pagamento, chiamate audio via relay** — già fuori scope della mappa Relay.
