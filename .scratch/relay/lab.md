# Lab a tre nodi — sequenza riproducibile

Obiettivo: due client Prysm (A, B) + un terzo nodo Tor con hidden service,
tutti su Tor reale, per le prove dal vivo del Relay.
Sessione di riferimento: 2026-09-12 (branch `feat/same-account-transfer`).

Identità della sessione (effimere, distrutte al teardown):
- A (`prysm-lab`): `x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion`
- B (`prysm-lab-b`): `y2smgkwc3vos5vlx5jencmhvyr5z3ufqyzrscfzgkhdlwx26gum3asad.onion`
- relay (`prysm-lab-relay`): onion effimero, rigenerato a ogni setup — mai
  trascriverlo qui; si legge nel container con `cat ~/relay/hs/hostname`
  (nodo di probe §4 e nodo Relay vero §5 hanno HS distinti).

## 0. Preflight

```sh
tool/live/prysmlab doctor
```

Esito atteso: `ok docker usable`, `ok image prysm-lab present`, `ok rsync
present`, `ok repo tor binary present`, exit 0. Nota: l'immagine
`prysm-l3e2e:latest` (5.62 GB, base Flutter) NON è il lab — `doctor` cerca
`prysm-lab`. Se manca, costruirla (il 2026-09-12 è riuscita al primo colpo,
tutto cached, ~2 s di export; senza cache servono minuti):

```sh
tool/live/prysmlab build-image
```

Comandi lunghi (`build-image`, prima `up`): usare `hub` op:`start` oppure
bash con `timeout: 0` — mai bloccare la sessione.

## 1. Lab A (default) e lab B (override env)

```sh
tool/live/prysmlab up --timeout 1500
tool/live/prysmlab onboard --pin 123456
tool/live/prysmlab screen   # atteso: HomeScreen

PRYSMLAB_CONTAINER=prysm-lab-b PRYSMLAB_HOST_LAB=/tmp/prysm-lab-b \
  PRYSMLAB_VOLUME=prysm-lab-b-pub tool/live/prysmlab up --timeout 1500
PRYSMLAB_CONTAINER=prysm-lab-b PRYSMLAB_HOST_LAB=/tmp/prysm-lab-b \
  PRYSMLAB_VOLUME=prysm-lab-b-pub tool/live/prysmlab onboard --pin 123456
```

Tempi osservati il 2026-09-12: `up` ~35 s per lab (staging + compile della
prima run), `onboard` ~22 s. Entrambi raggiungono `HomeScreen`.

Alias comodo per tutta la sessione (ogni comando B ne ha bisogno):

```sh
BENV="PRYSMLAB_CONTAINER=prysm-lab-b PRYSMLAB_HOST_LAB=/tmp/prysm-lab-b PRYSMLAB_VOLUME=prysm-lab-b-pub"
```

## 2. Onion e ID base58

```sh
tool/live/prysmlab peer onion
env $BENV tool/live/prysmlab peer onion
tool/live/txlab onion b        # stampa onion + base58 di B (config b = prysm-lab-b)
```

`txlab` conosce solo i peer `a=prysm-lab-a, b, c, droid`: il nostro A è il
default `prysm-lab`, quindi il base58 di A va calcolato a mano (stesso codec
di `tool/live/txlab:198-211`, specchio di `lib/util/onion_id_codec.dart`):

```sh
python3 -c "
BASE58='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
raw=b'<56 chars, senza .onion>'
n=int.from_bytes(raw,'big'); b58=''
while n: n,d=divmod(n,58); b58=BASE58[d]+b58
print(b58)"
```

## 3. Contatto reciproco (pairing reale su Tor)

Sul dialogo Add contact l'ordine degli `EditableText` è
**[0]=casella di ricerca (dietro il dialogo), [1]=User ID, [2]=Display name**
— `type` senza `-n` scrive nella ricerca, NON nel dialogo. Verificare con
`screen` che gli hint `eg. …` spariscano e che `Search chats and
messages...` resti:

```sh
tool/live/prysmlab tap "Add contact"
tool/live/prysmlab type -n 1 "<base58-di-B>"
tool/live/prysmlab type -n 2 "PeerB"
tool/live/prysmlab tap "Add"   # dialogo: "Looking up contact on Tor..."
```

Ripetere su B con il base58 di A e nome `PeerA`. Numeri osservati:
- A→B a circuiti tiepidi ma descriptor mai visti: ~90-120 s (bracketing
  largo, vedi trabocchetto 6), contro 5.5-7.9 s della skill;
- B→A a tutto caldo: submit→dialogo chiuso in ~5 s (conferma la skill).

Trabocchetto: su A la tile `PeerB` NON appare finché non si riavvia
(`tap "PeerB"` → `NOTFOUND`, conteggio `0 contacts`→`1 contact` ma tile
assente — refresh della lista, cfr. skill regola 17/nota 2):

```sh
tool/live/prysmlab restart
tool/live/prysmlab onboard --pin 123456   # restart: 5.3 s, onboard: 4.0 s
tool/live/prysmlab count "PeerB"          # -> 1
```

Poi aprire le chat: `tap "PeerB"` su A, `tap "PeerA"` su B (ChatScreen).

## 4. Terzo nodo (Tor + hidden service + HTTP di prova)

```sh
docker run -d --name prysm-lab-relay ubuntu:24.04 sleep infinity
docker exec prysm-lab-relay apt-get update
docker exec prysm-lab-relay apt-get install -y --no-install-recommends tor curl python3
docker exec prysm-lab-relay bash -c "mkdir -p /tmp/relay-hs /tmp/relay-www /tmp/relay-data \
  && echo 'prysm-relay-probe-ok' > /tmp/relay-www/index.txt \
  && printf 'SocksPort 127.0.0.1:9050\nDataDirectory /tmp/relay-data\nHiddenServiceDir /tmp/relay-hs\nHiddenServiceVersion 3\nHiddenServicePort 80 127.0.0.1:8080\n' > /etc/tor/torrc-relay"
docker exec -d prysm-lab-relay tor -f /etc/tor/torrc-relay
docker exec -d prysm-lab-relay python3 -m http.server 8080 --bind 127.0.0.1 --directory /tmp/relay-www
docker exec prysm-lab-relay cat /tmp/relay-hs/hostname   # l'onion, dopo il bootstrap

TRAPPOLA ownership: tor gira come root ma il pacchetto Debian assegna
`/var/lib/tor` e `/tmp/relay-hs` a `debian-tor` → `Failed to
parse/validate config`. Soluzione usata: tutto sotto `/tmp/relay-*`
posseduto da root (`chown -R root:root`, `DataDirectory /tmp/relay-data`).

Prova del percorso completo — dai container dei client, via il SOCKS del
Tor DELL'APP (default 9050, `lib/util/tor_service.dart:68,811`):

```sh
docker exec prysm-lab   curl -s -m 300 --socks5-hostname 127.0.0.1:9050 http://<onion>/index.txt
docker exec prysm-lab-b curl -s -m 300 --socks5-hostname 127.0.0.1:9050 http://<onion>/index.txt
# atteso: prysm-relay-probe-ok
```

Numeri osservati: self-test dal relay 112 s (prima fetch: propagazione del
descriptor HS + circuiti), poi **4 s da A e 8 s da B**. Le chiavi HS sono
effimere: a ogni setup l'onion cambia, nessun backup serve.

Questo nodo resta anche dopo il §5: è lo smoke test della raggiungibilità
onion, distinto dal Relay vero.

## 5. Nodo Relay Prysm

Il Relay vero con cui il 2026-09-12 si è provata la consegna a peer spento.
Riutilizza il container del §4 (`prysm-lab-relay`): se il probe gira ancora,
fermarlo prima (`pkill tor` e `pkill -f "http.server"` nel container) oppure
ricreare il container da zero. Comandi in quest'ordine, tutti dall'host:

```sh
docker run -d --name prysm-lab-relay --entrypoint sleep prysm-lab infinity
docker exec prysm-lab-relay bash -lc 'mkdir -p ~/relay/packages ~/relay/tordata ~/relay/hs && chmod 700 ~/relay/hs'
docker cp packages/prysm_relay_protocol prysm-lab-relay:/home/ubuntu/relay/packages/prysm_relay_protocol
docker cp packages/prysm_relay_server prysm-lab-relay:/home/ubuntu/relay/packages/prysm_relay_server
docker cp tor_executable/tor prysm-lab-relay:/home/ubuntu/relay/tor
docker exec prysm-lab-relay bash -lc 'cd ~/relay/packages/prysm_relay_server && dart pub get'
# torrc: SocksPort 0 / DataDirectory ~/relay/tordata / HiddenServiceDir ~/relay/hs /
#        HiddenServiceVersion 3 / HiddenServicePort 80 127.0.0.1:8443
docker exec prysm-lab-relay bash -lc 'nohup ~/relay/tor -f ~/relay/torrc > ~/relay/tor.log 2>&1 &'
# ~25 s -> cat ~/relay/hs/hostname
docker exec prysm-lab-relay bash -lc 'cd ~/relay/packages/prysm_relay_server && dart run bin/prysm_relay.dart init --data-dir /home/ubuntu/relay/data --tenancy private --port 8443 --onion <onion>'
# poi `serve` come processo supervisionato dal broker (hub op:"start", name relay-serve)
```

Trabocchetti inline, uno per riga:
- immagine `prysm-lab` e non `ubuntu:24.04`: il Dart SDK c'è già, il §4
  doveva installare tor/curl/python via apt proprio perché partiva da Ubuntu
  liscio;
- `dart pub get` **senza** `--offline`: la pub cache del lab è incompleta e
  con `--offline` fallisce;
- onion e token di setup sono **effimeri, rigenerati a ogni `init`**: il
  token è un segreto monouso, non va mai incollato in un documento
  versionato (qui non compare né l'uno né l'altro);
- `serve` va supervisionato (nome `relay-serve`) e non lanciato in
  foreground nella sessione, altrimenti muore con la shell;
- il Relay ascolta **solo loopback** e Tor è l'unico ingresso: nessun
  `HiddenServicePort` punta altrove e nessuna porta è pubblicata su docker.

Prova end-to-end (numeri del 2026-09-12):
- pairing dalla UI di B verso A e contatto reciproco (come al §3);
- messaggio online A↔B come sanity (consegna diretta, vedi §6);
- spegni B: app **e** tor (con l'app muore anche il suo tor, vedi §7);
- messaggio da A a B spento: il deposito parte ~60 s dopo il tap perché
  prima scade il budget WebSocket del mittente (preesistente, non del relay);
- riaccendi B (`restart` + `onboard`, vedi §7) e verifica **dentro il
  container di B** (i log runtime dell'app NON sono in `~/lab/app.log`):
  ```sh
  docker exec prysm-lab-b grep "Relay pickup delivered" /tmp/prysm_chat.log
  ```
  più la bubble nella chat. Osservato: `Relay pickup delivered 1` 7 s dopo
  la HomeScreen di B; 656 B in chiaro → 1072 B sigillati sul disco del
  Relay; dopo l'ack `items=0 bytes=0` con la mailbox ancora registrata.

## 6. Baseline misurata (2026-09-12)

Invio dal composer (su ChatScreen gli `EditableText` sono
[0]=ricerca, [1]=composer; su desktop `onSubmitted` è null —
`lib/screens/message_composer.dart:395` — si spedisce SOLO col pulsante
`PrysmIconButton` chiave `send`):

```sh
tool/live/prysmlab type -n 1 "relaybase MARK<n> ..."
T0=$(date +%s); tool/live/prysmlab tap-widget --type PrysmIconButton --contains send
```

ATTENZIONE — le bubble sono `RichText`, non `Text`: `wait`/`count` (vedono solo `Text`) sono CIECHI alle bubble consegnate. Polling che
funziona (loop host ogni 2-3 s, vedi §7):

```sh
tool/live/prysmlab eval "(() { final b = WidgetsBinding.instance; int n = 0; void walk(Element e) { final dynamic w = e.widget; final String t = w.runtimeType.toString(); if ((t == 'RichText' || t == 'Text') && w.toString().contains('MARK<n>')) { n++; } e.visitChildren(walk); } final r = b.rootElement; if (r == null) return 'ERR'; walk(r); return '' + n.toString(); })()"
# bubble resa = 2 hit (Text + RichText)
```

Consegna diretta A→B, entrambi online, link caldo dopo restart di A:
- MARK2: inviato 1789206374 → reso su B 1789206387 = **12-13 s**;
- MARK3: inviato 1789206393 → reso su B 1789206397 = **4 s**;
- MARK1: consegnato e reso su entrambi i lati (2+2 hit), bracketing largo
  per via del trabocchetto `wait` (inviato 09:42:01, confermato ≤09:48).
  Più lento del mediano 0.43 s wire / 1.47 s render della skill: qui c'era
  di mezzo un restart di A con re-handshake WS e flap di presence
  Offline→Online. n piccolo, valore indicativo, non mediano.

Drain a peer offline (B spento, vedi §7): 3 messaggi inviati da A a B
morto, B riavviato → **3/3 resi ≤9 s dopo la HomeScreen** (25 s
dall'istante del `restart`, boot+tor+onboard inclusi). Conferma gli 8-11 s
della skill.

## 7. Drain test — spegnere B senza perdere l'identità

```sh
docker exec prysm-lab-b bash -c 'pkill -f "[f]lutter_tools.snapshot run"; sleep 3; echo KILLED'
```

- Le parentesi quadre nel pattern evitano che `pkill` uccida la shell che
  lo contiene (senza: esce 143 e non si capisce cosa è morto).
- OSSERVATO: con l'app muore anche il suo tor (processo sparito) → B è
  *del tutto* offline (caso "peer spento"), non "app chiusa + tor vivo".
  L'identità sopravvive (keyring + `~/Documents/prysm/*.db` nel layer
  scrivibile del container, container vivo). Alternativa documentata, non
  realizzata: uccidere solo il bundle `Prysm` lasciando tor in piedi.
- Inviare N messaggi da A (restano in coda: 3 bubble viste su A, 6 hit),
  poi:

```sh
env $BENV tool/live/prysmlab restart        # rilancia app + tor
env $BENV tool/live/prysmlab onboard --pin 123456
env $BENV tool/live/prysmlab tap "PeerA"    # aprire la chat: le bubble vivono solo lì
# polling eval del §6 finché DRAIN1..3 = presenti
```

## 8. Teardown completa

1. fermare il processo supervisionato `relay-serve` dal broker (hub `stop`
   sul nome `relay-serve`), e solo dopo toccare docker;
2. rimuovere il container:

```sh
docker stop prysm-lab-relay && docker rm prysm-lab-relay
```

Poi i lab:

```sh
tool/live/prysmlab down --purge
env $BENV tool/live/prysmlab down --purge
docker ps --format '{{.Names}}'              # nessun prysm-lab* vivo
docker volume ls | grep -i prysm-lab || echo "volumi lab rimossi"
```

`down --purge` rimuove container, volume pub-cache, staging e immagine, e
stampa il blocco di verifica (container/volume/staging/image residui,
processi tor host, `git status`). Nota: rimuove anche l'immagine
`prysm-lab` (~7 GB) — la rebuild è cached e veloce (`tool/live/prysmlab
build-image`, vedi §0).

## 9. Trabocchetti (pagati in questa sessione)

1. `prysm-l3e2e:latest` ≠ immagine lab: `doctor` vuole `prysm-lab`,
   costruirla con `build-image`.
2. `type` senza `-n` nel dialogo Add contact scrive nella SEARCH, non
   nell'ID (ordine [search, userid, display]); sul composer di ChatScreen
   l'indice giusto è `-n 1`.
3. `wait`/`count` non vedono le bubble (RichText): un `TIMEOUT waiting`
   NON significa "non consegnato" — verificare con l'eval walk Text+RichText.
4. Chiamate `bash` parallele con env diversi: i risultati possono
   arrivare attribuiti in modo ambiguo — riverificare in serie i fatti
   chiave (con `echo CONTAINER=…` nell'output).
5. tor nel terzo nodo: directory possedute da `debian-tor`, tor come root
   non parte — usare dir dedicate possedute da root.
6. Bracket larghi dove il polling era cieco (MARK1, pairing A→B): i numeri
   marcati "coarse" vanno riusati come ordini di grandezza, non come medi.
7. `~/lab/app.log` contiene solo lo startup (banner flutter + cleanup
   tor): i log runtime dell'app NON ci arrivano — osservare via tree
   (`screen`/`count`/eval) e via DB in-app, non via `logs --grep`.
8. `restart` di B ha ucciso anche il suo tor: il drain misurato include il
   bootstrap tor a freddo del peer che ritorna.
9. Prima fetch verso un HS nuovo: ~112 s; non è un bug, è propagazione
   descriptor + circuiti. Le fetch successive: 4-8 s.
10. **L'albero dei widget può essere STALE: il pipeline dei frame si blocca.**
    Il più costoso di tutti, pagato da Main il 2026-09-12. Sintomo: lo stato
    dell'app è avanzato ma `screen`/`shot` mostrano la schermata di prima, e
    ogni tap sembra non avere effetto. Osservato durante l'onboarding:
    `_unlockSetupComplete=true` e `_setupPin='223311'` letti dallo State vivo,
    mentre l'albero conteneva ancora `Create your PIN` + `PinKeypad` +
    `PinDots(filledCount: 3)` — cioè il build del branch
    `if (_unlockSetupComplete)` (`lib/screens/onboarding/onboarding_screen.dart:540`)
    non era mai stato eseguito, benché `setState` fosse stato chiamato (`:212`).
    Diagnosi e sblocco:
    ```sh
    tool/live/prysmlab eval "(() { final b = WidgetsBinding.instance; b.scheduleForcedFrame(); return 'lifecycle=' + b.lifecycleState.toString() + ' framesEnabled=' + b.framesEnabled.toString(); })()"
    # -> lifecycle=AppLifecycleState.resumed framesEnabled=true, e l'albero si aggiorna
    ```
    Regola operativa: **prima di concludere "la UI non si aggiorna", forzare un
    frame e ri-osservare.** Un `screen` che contraddice lo State non è un bug
    dell'app finché non è stato confermato con un frame forzato. `framesEnabled`
    e `lifecycleState` restano sani, quindi non servono come sentinella: l'unico
    test valido è forzare il frame.
11. **`--lib` è STICKY e rompe `onboard`.** Dopo un `eval --lib
    package:prysm/...`, i comandi interni di `prysmlab` girano in quella
    libreria e `onboard` muore con `Error: Method not found: 'HitTestResult'`
    (lo stato è in `lib_uri`, `tool/live/prysmlab:423-431`). Stessa radice
    rompe anche `where`, `tap-widget` ed `eval` successivi, con errori dal
    caret illeggibile. Reset:
    ```sh
    tool/live/prysmlab eval --lib "widgets/binding.dart" "1+1"   # -> 2
    ```
12. **`onboard --pin` con cifre ripetute non funziona.** Con `--pin 112233` il
    pad registra **3** cifre su 6 (i tap consecutivi sulla stessa cifra vengono
    inghiottiti) e `onboard` gira a vuoto: osservate 30 passate consecutive
    (`pin pad (entry 1..30)`), PIN finale scrambled `223311`. Nel lab corrente
    il PIN è **123456** (cifre distinte) e tutti gli `onboard` di questo
    runbook lo usano già — la §1, che usava ancora `--pin 112233`, è stata
    corretta con questo trabocchetto in mano. In alternativa battere le cifre
    a mano con `sleep 1` fra i tap e verificare i pallini con `shot`.
13. **`SettingsScreen` non ha un bottone con testo.** `tap "Settings"` risponde
    `NOTFOUND n=0`: il controllo è un'icona avvolta in
    `Semantics(label: tooltip)` (`lib/screens/home/home_screen.dart:1403-1407`).
    Si apre così:
    ```sh
    tool/live/prysmlab tap-widget --type Semantics --contains "Settings"
    ```
    Nemmeno `--type Tooltip --contains Settings` funziona (il widget non è un
    `Tooltip` e il suo `toString` non contiene la label).
14. **Il primo giro verso l'onion del Relay non sta nei 30 s del client.**
    Misurato il 2026-09-12 dopo un `restart` di B: `curl --socks5-hostname`
    verso `/relay/manifest` ha risposto 200 in **39,8 s**, mentre
    `RelayClient.defaultTimeout` è 30 s per tentativo — quindi
    `refreshStatus` all'apertura della schermata muore in timeout, la UI
    resta su `Loading relay status…` e la lista mailbox sembra vuota. Al
    secondo tentativo (circuito caldo) lo stesso `refreshStatus` chiude in
    < 20 s e la riga compare. Regola: **prima di dichiarare un bug del Relay,
    ripetere la chiamata a circuito caldo**; i `TimeoutException` di
    `Relay pickup failed` nella stessa finestra sono la stessa cosa, e il
    pickup li ritenta da solo.
15. **Il bug trovato così era reale, ed era nella UI, non nella rete.**
    `_RelaySettingsScreenState.initState` chiamava `_onRefreshStatus()`, che
    legge `context.l10n` e fa `setState`: entrambi illegali durante
    `initState`. Effetto: `Zone error:
    dependOnInheritedWidgetOfExactType<_LocalizationsScope>() ... before
    initState() completed` in `/tmp/prysm_chat.log` e **nessuna** refresh mai
    eseguita — la lista "Contacts on this relay" restava vuota anche con la
    mailbox registrata sul Relay (verificato su disco:
    `~/relay/data/tenants/<fpr>/mailboxes/<deposit>/policy.json`). Corretto
    con `addPostFrameCallback` e difeso da
    `test/relay_settings_screen_test.dart` ("opening the screen while paired
    refreshes the relay status"). Morale: **il log runtime in
    `/tmp/prysm_chat.log` va letto dopo ogni schermata nuova**, non solo
    quando qualcosa si vede rotto.
