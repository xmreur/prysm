# Pubblicazione e aggiornamenti: come spediscono gli altri

Type: research
Status: resolved

## Question

Fatti esterni che mancano alle decisioni di packaging: come spediscono e versionano artefatti analoghi (binario custom + Tor) i progetti affini, e quali meccanismi di update non richiedono inventare nulla?

Da accertare alle fonti (AFK — solo lettura, nessuna decisione qui):

1. Registro e tag: GHCR/Docker Hub per immagini di servizio single-binary — schemi di tag immutabili vs `latest`, multi-arch, firma/attestazione (cosign/sigstore) e SBOM: cosa è standard a costo zero con GitHub Actions?
2. Distribuzione nativa senza Docker: tarball versionati su GitHub Releases + checksum, repo apt minimale, o binario auto-aggiornante — cosa usano i progetti Dart `compile exe` / Go single-binary comparabili, e cosa costa mantenerlo?
3. Coppia Tor + app custom: esempi di immagini che cuociono Tor di sistema con un binario sopra (base scelta, dimensione finale, come seguono gli update di sicurezza di Tor senza rebuild continui)?

## Context

- Vincoli: immagine policy-driven unica o flavor (ticket immagine), percorso nativo primario o fallback (ticket systemd) — la ricerca li alimenta, non li risolve.
- CI esistente: `analyze-and-test`, CodeQL, Analyze esterne; release attuale: nessuna pubblicazione relay (branch `feat/relay-v1`, PR #174).
- Trovati notevoli: SimpleX/Briar/chatmail solo se toccano *distribuzione* del server (non il protocollo, già deciso nella mappa Relay).

## Done when

- Findings in `.scratch/relay-create/research/06-<slug>.md` con fonti linkate, tabella opzioni → costo di mantenimento, e raccomandazione esplicita ma non vincolante per i ticket 02 e 03.
- Niente codice, niente decisioni: solo fatti datati (le API dei registri cambiano in fretta).

## Resolution

Chiuso come research: fatti alle fonti (verifica 2026-09-12 → 2026-09-13) in
[research/06-pubblicazione-aggiornamenti.md](../../research/06-pubblicazione-aggiornamenti.md).
Gist: GHCR senza immutabilità nativa (digest pin + check no-overwrite in CI) contro
immutable-tags beta di Docker Hub; multi-arch buildx e provenance/SBOM keyless gratis;
canale nativo primario = tarball su Releases + SHA256 (modello Caddy/SimpleX), niente
repo apt self-hosted né auto-update; Tor seguito con rebuild schedulato su
Debian-security. Raccomandazione esplicita ma non vincolante per i ticket immagine e
systemd nella stessa pagina.
