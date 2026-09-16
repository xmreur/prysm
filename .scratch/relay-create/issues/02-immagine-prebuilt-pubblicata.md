# Immagine prebuilt pubblicata vs compilazione ogni volta

Type: grilling
Status: resolved

## Question

Decisione di packaging: cuocere binario Relay + Tor in **un'immagine versionata e pubblicata** (provisioning = `docker run` da pochi secondi, niente Dart SDK né apt al momento del bisogno) oppure tenere lo script che compila e installa ogni volta?

Da decidere con grilling (HITL — la risposta impegna supply chain e release):

1. Una sola immagine policy-driven (Private = `max_tenants: 1`, come oggi) o flavor private/public separati?
2. Dove vive e come si versiona: GHCR con tag per versione binario + `prysm-relay/1`, `latest` mobile o solo tag immutabili?
3. Chi compila e con cosa: CI esistente (`analyze-and-test`, CodeQL) estesa a build+push, SBOM/provenance sì o no?
4. Cosa resta dello script: thin wrapper sopra `docker run` (domande, volumi, token) o pensionato?
5. Base minimale (distroless/alpine + tor statico?) vs `ubuntu:24.04` attuale: quanto pesa il risparmio contro il costo di mantenere un'altra base?

## Context

- Baseline di [Misure del costo di creazione attuale](01-misure-costo-creazione-attuale.md): senza i suoi numeri, questo ticket discute alla cieca — non risolverlo prima.
- Findings di [Pubblicazione e aggiornamenti: come spediscono gli altri](06-pubblicazione-aggiornamenti-come-spediscono-gli-altri.md): se pronti, usali; altrimenti decidi con i fatti noti e annota cosa rivalutare.
- Vincoli: Dart puro, `prysm-relay/1` intatto, loopback-only; `init` idempotente e `serve` invariati.
- Stato attuale: `create_relay.sh` compila in un temp file (rimosso su exit) o riusa `--binary`; re-run sicuro ( riusa container, tiene identità, menta token fresco).

## Done when

- Scelta immagine unica vs flavor + registro + schema di tag scritti nella risoluzione.
- Ruolo futuro dello script (wrapper vs pensionato) e base image scelti, con motivo.
- Criterio di accettazione misurabile: tempo di provisioning da immagine fredda che batte il baseline del ticket 01.

## Resolution

Deciso con l'utente: **immagine unica policy-driven** — nessun flavor private/public
separato. Dettagli tecnici adottati dai findings research come default (revocabili in
esecuzione): registro GHCR, tag `:vX.Y.Z` + `:latest` mobile + pin per digest, check
no-overwrite in CI, provenance/SBOM gratis, base `debian:trixie-slim`, rebuild
schedulato + Dependabot. Ruolo futuro dello script: thin wrapper sopra `docker run`.
