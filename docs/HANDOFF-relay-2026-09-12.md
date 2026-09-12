# Handoff — Relay di Prysm (aggiornato: fine sessione 2026-09-12, seconda parte)

Documento permanente in `docs/`, versionato col repo. Sostituisce la versione precedente dello
stesso file: tutto ciò che conteneva vive ora nei documenti permanenti (vedi §2), quindi qui resta
solo ciò che serve a chi riprende.

Obiettivo dell'utente, invariato:

> «i relay devono essere **funzionanti**, **già testati** (con live app testing, correggendo i bug
> dal vivo) e **dettagliatamente documentati**, sia nel funzionamento sia nel come si utilizzano».

Lingua: mappa, ticket, lab e questo handoff in italiano; codice, identificatori, spec, `CONTEXT.md`
e documentazione in inglese.

---

## 1. Stato: obiettivo raggiunto

Le tre condizioni della destinazione (`.scratch/relay/map.md`) sono soddisfatte:

1. **Funziona**: messaggio consegnato da A a B con B **completamente spento** (app *e* tor uccisi),
   passando dal Relay. Prova visiva: [`relay-offline-delivery-proof.png`](./relay-offline-delivery-proof.png).
2. **Provato dal vivo**: percorso di deposito/pickup, schermata Relay accoppiata, manifest preview
   su peer non accoppiato e rifiuto di Pairing su Relay Private — tutto esercitato con
   `live-app-testing`, e i **due bug trovati sono stati corretti nella stessa sessione** (§3).
3. **Documentato**: `docs/RELAY.md` (funzionamento + threat model + limiti v1),
   `docs/RELAY-USER.md` (guida utente dall'app), `packages/prysm_relay_server/README.md` (guida
   operatore completa: systemd, backup, quote, monitoraggio, upgrade, dismissione, troubleshooting).

Branch: **`feat/relay-v1`**, 6 commit **solo locali** (nessun push, per richiesta dell'utente):

```
06793a5 fix(relay): label the relay fingerprint in the manifest preview
dcb2146 ci(relay): analyze and test both Dart packages; close the last relay ticket
29ddd4b docs(relay): how it works, user guide, operator guide, honest READMEs
6dde598 fix(relay): refresh the relay status after the first frame, not inside initState
a4fd3f4 docs(relay): glossary, ADR, normative protocol spec, tracker and handoff
3b504cb feat(relay): client-side pairing, sealed deposit, pickup and relay settings UI
53814ed feat(relay): pure-Dart relay protocol package and standalone relay server
```

Working tree pulito. Il branch parte da `feat/same-account-transfer`. **Decisione aperta**: se e
come integrarlo (merge/rebase su main) e se pubblicarlo.

## 2. Dove leggere, invece di ricostruire

| Cosa | Dove |
|---|---|
| Legge normativa del wire | `.scratch/relay/proto/relay-protocol-v1.md` — leggila prima di toccare qualsiasi cosa |
| Decisione sul formato | `docs/adr/0001-relay-sealed-mailbox.md` |
| Glossario di dominio | `CONTEXT.md` |
| Come funziona + threat model + limiti v1 + mappa del codice | `docs/RELAY.md` |
| Guida utente (UI, errori, cosa vede l'operatore) | `docs/RELAY-USER.md` |
| Guida operatore (CLI, config, storage, torrc, systemd, backup, quote) | `packages/prysm_relay_server/README.md` |
| Decisioni per ticket (16 indicizzate) e nebbia residua | `.scratch/relay/map.md` |
| Runbook del lab a tre nodi + ricetta del nodo Relay + 15 trabocchetti | `.scratch/relay/lab.md` |

## 3. Bug trovati dal vivo in questa sessione (corretti, con test)

1. **La schermata Relay non rinfrescava mai lo stato.** `initState` chiamava `_onRefreshStatus()`,
   che legge `context.l10n` e fa `setState`: entrambi illegali durante `initState`. Il log dentro
   il container (`/tmp/prysm_chat.log`) diceva `Zone error:
   dependOnInheritedWidgetOfExactType<_LocalizationsScope>() ... before initState() completed`, e
   l'effetto osservabile era "Contacts on this relay" vuoto anche con la mailbox registrata sul
   Relay (verificato sul disco del Relay). Fix: `addPostFrameCallback`. Difeso da
   `test/relay_settings_screen_test.dart` → *opening the screen while paired refreshes the relay
   status* (fallisce pre-fix con lo stesso zone error).
2. **L'impronta del Relay era mostrata senza etichetta** nella manifest preview: l'unico valore che
   l'utente deve confrontare fuori banda era una stringa hex muta accanto al chip Private/Public.
   Fix: `_FactRow` etichettata (`Fingerprint`), impilata sopra il chip — i widget test hanno
   intercettato l'overflow di 54 px a 400 px di larghezza.
3. **`flutter test` completo era rosso su 16 test** da prima di questa sessione: lo schema v19
   (`users.relayAdvertisement`, `relay_mailboxes`) era arrivato senza aggiornare quattro fixture e
   asserzioni di migrazione (`user_version` 18 → 19). L'handoff precedente non lo aveva visto
   perché §7 eseguiva solo il test della schermata Relay. Corretto; le asserzioni di migrazione ora
   verificano anche le colonne v19, non solo il numero di versione.

## 4. Fatto anche (meccanico)

- **CI** (`.github/workflows/ci.yml`): due step nuovi nello stesso job, `dart pub get && dart
  analyze && dart test` in `prysm_relay_protocol` e `prysm_relay_server` (mai `--offline`: in CI la
  pub cache è vuota). `prysm_relay_server` non deve mai diventare dipendenza della app: 0 import in
  `lib/` e `test/`.
- **Ticket 15** chiuso con evidenza reale (`Status: resolved`): simboli esportati, prova di
  indipendenza da Flutter, elenco file per file delle seam.
- **Mappa**: indicizzate le 11 decisioni mancanti (01, 05-14), graduata la nebbia diventata fatto
  (superficie, storage, adapter, UI, deploy/ops, documentazione), aggiunta la nebbia deliberata.
- **`lab.md`**: ricetta del nodo Relay Prysm, prova end-to-end con i numeri, trabocchetti 14 e 15.
- **CHANGELOG + `pubspec.yaml`**: sezione `## 0.8.0`, versione app 0.7.1 → 0.8.0.
- **Teardown eseguito**: nessun container, volume, staging, immagine o processo del lab rimasto.

## 5. Numeri misurati (riusali, non ri-scoprirli)

- deposito: 656 B di envelope in chiaro → **1072 B** sigillati sul disco del Relay (~1,6×);
- il deposito parte ~60 s dopo il tap (prima scade il budget WS del mittente, comportamento
  preesistente);
- pickup: `Relay pickup delivered 1` **7 s** dopo la HomeScreen del destinatario; dopo l'ack
  `items=0 bytes=0` con mailbox ancora registrata;
- **primo giro verso l'onion del Relay: 39,8 s** (`curl` via SOCKS), contro i **30 s** di
  `RelayClient.defaultTimeout` per tentativo → la prima `refreshStatus` dopo un restart va in
  timeout e la UI resta su `Loading relay status…`; al secondo tentativo (< 20 s) la lista mailbox
  compare. Il pickup ritenta da solo, quindi non è stato cambiato nulla: è documentato nella guida
  utente e nel trabocchetto 14 del lab;
- `dart compile exe` → **8.017.952 byte (7,6 MiB)**, standalone;
- audit del blob salvato: nessuna occorrenza di mittente, destinatario, testo o `groupId`.

## 6. Cosa resta (nessuno è bloccante)

1. **Integrazione del branch**: decidere con l'utente merge/rebase e se pubblicare.
2. **Nebbia deliberata**, in `map.md`: padding (`blockSize` è già 0 nel Contract) e pickup civetta,
   spooler outbound, ridondanza multi-relay, Relay co-ospitato, API blob per gli allegati, prekey
   serviti dal Relay, delivery receipt, compatibilità wire. Ognuna è una decisione da prendere con
   `grilling`, non un TODO da implementare.
3. **Altri scenari da promuovere a test**: quota piena, whitelist che rifiuta, gruppo con membri
   misti (la policy di Pickup e la refresh della schermata sono già coperte).
4. `docs/THREAT_MODEL.md` **non esiste** e i README non lo citano più (il link pendente è stato
   corretto): se lo si vuole, è un effort sull'app, non sul Relay.

## 7. Insidie da conoscere prima di scrivere codice

- `SettingsService()` è il singleton (non `.instance`); `RelayService.instance` sì.
- `INSERT OR REPLACE` su `users` distrugge le colonne non ricopiate: se aggiungi una colonna,
  cercane **tutti** gli scrittori **e tutte le fixture nei test** (questa sessione ne ha pagate 4).
- `_validateAddressedToLocal` risponde 403 se `receiverId` non è l'onion locale: il pickup **deve**
  restituire l'envelope originale, non ri-avvolto.
- `POST /message` via WebSocket risponde con un **ack ottimistico**: "A dice inviato" non è prova di
  arrivo, guarda la tabella `messages` del destinatario.
- I log runtime dell'app sono in `/tmp/prysm_chat.log` **dentro il container**, non in
  `~/lab/app.log`. Leggili dopo ogni schermata nuova: è così che è emerso il bug nº 1.
- `SettingsScreen` è un ramo del build di `HomeScreen`; la schermata Relay è una route
  (`pop` funziona). Si apre con `tap-widget --type Semantics --contains "Settings"`, poi
  `tap "Relay"`.
- Nel lab: PIN a **cifre distinte** (`--pin 123456`), `--lib` è **sticky** (reset con
  `eval --lib "widgets/binding.dart" "1+1"`), e `restart --sync` può incastrare un peer su
  `UnlockScreen` — un `restart` liscio lo recupera (visto anche in questa sessione).

## 8. Come verificare che tutto è ancora in piedi

```sh
cd /home/mike/Documenti/prysm
flutter analyze                 # atteso: No issues found!
flutter test                    # atteso: +1265 ~1 All tests passed (1 skip = harness L3, gated)
(cd packages/prysm_relay_protocol && dart analyze && dart test)   # 23/23
(cd packages/prysm_relay_server   && dart analyze && dart test)   # 23/23
(cd packages/prysm_relay_server   && dart compile exe bin/prysm_relay.dart -o /tmp/prysm-relay)
```

Per la prova dal vivo: `.scratch/relay/lab.md` (§1 i due client, §5 il nodo Relay, §7 il drain).
Il lab è stato smontato: va ricostruito da zero, e l'onion del Relay è effimero per costruzione.

## 9. Skill da chiamare

`live-app-testing` (obbligatoria per qualunque modifica al client), `writing-for-agents` (documenti
per agenti), `domain-modeling` (termini nuovi → `CONTEXT.md`, decisioni → `docs/adr/`), `grilling`
(le decisioni della nebbia, §6.2), `ponytail` (quando un documento o un ticket si gonfia),
`context-saving` (handoff della prossima sessione). `wayfinder` non è installata in questo host: la
mappa si lavora a mano seguendo le sue regole (un ticket decisionale per sessione).
