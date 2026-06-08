# Prysm

[🇬🇧 English](README.md) | [🇮🇹 Italiano](README.it.md)

<p align="center">
  <img src="https://cdn.discordapp.com/icons/1420770528691617928/e685f1b4b88adc1b6a8da534633b7fca.png?size=512" width="320" alt="Logo Prysm">
</p>

Prysm è un messenger P2P basato su Tor, costruito con Flutter.

Non c'è nessun server centrale. Ogni client espone un servizio hidden Tor, riceve messaggi direttamente sul suo indirizzo `.onion` e invia messaggi in uscita tramite Tor. Se un peer è offline, i messaggi restano in una coda locale e vengono riprovati più tardi.

## Panoramica

Prysm funziona come un messenger peer-to-peer diretto su servizi hidden Tor.

Su desktop, Tor viene avviato come processo child. Su Android, è avviato tramite un servizio nativo. L'app espone anche un server HTTP locale con `shelf`, in ascolto sulla porta `12345`, che Tor rende disponibile come `your-address.onion:80`. I messaggi in uscita sono inviati tramite il proxy SOCKS5 di Tor verso `peer-address.onion:80/message`. `shelf` è una libreria Dart per middleware HTTP, spesso usata per costruire server leggeri e compositi, che si adatta bene a questo modello di trasporto locale.

Non ci sono server relay al momento. Le impostazioni relay esistono nell'UI, ma sono placeholder e non implementate.

## Flusso dei messaggi

Se entrambi i peer sono online, i messaggi arrivano in genere entro pochi secondi.

Se il destinatario è offline o irraggiungibile, Prysm salva il messaggio localmente in SQLite e riprova con backoff esponenziale. Questo permette all'app di comportarsi come un messenger asincrono senza introdurre infrastrutture centralizzate.

## Crittografia

### Identità

- Keypair RSA-4096, generato localmente.
- Chiave privata crittografata a riposo con AES-256-GCM.
- Chiave di crittografia derivata dal PIN dell'utente con PBKDF2-HMAC-SHA256 in 100k iterazioni.

Gli indirizzi onion Tor sono separati dalle chiavi di identità di Prysm. Tor genera l'identità del servizio `.onion` dal suo materiale chiave. Le chiavi RSA di Prysm sono usate solo per la crittografia a livello applicativo.

### Messaggi diretti

- Messaggi di testo usano RSA PKCS#1 v1.5.
- File, immagini e audio usano un'inviluppo ibrido:
  - chiave AES-256-CBC random per ogni allegato
  - allegato crittografato con AES
  - chiave AES crittografata con RSA per mittente e destinatario

### Messaggi di gruppo

- I contenuti di gruppo usano AES-256-GCM con una chiave di gruppo condivisa.
- All'invito, la chiave di gruppo è crittografata con RSA per ogni membro.
- Alla rimozione di un membro, la chiave di gruppo è ruotata.

## Implementato

- Messaggistica 1:1 crittografata
- Allegati: immagini, file, audio, messaggi vocali
- Chat di gruppo con flusso di invito, rotazione chiave e rimozione membri
- Reazioni emoji
- Modificazione e cancellazione dei messaggi
- Confirmation di lettura con toggle
- Anteprima inline per PDF, `.docx`, `.xlsx`, immagini, audio e video
- Coda offline con ripartenza
- Scambio contatti tramite QR code o indirizzo `.onion` in base58
- Integrazione con tray su desktop
- Modalità panico con wipe o sessione deco
- Pin e archiviazione delle conversazioni
- Polling batteria-aware
- Link previews

## Non implementato

- Relay / proxy forwarding  
  Le impostazioni esistono nell'UI, ma non c'è nessun backend relay al momento.

## Piattaforme

Costruito con Flutter.

Obiettivi attuali:
- Linux
- Windows
- macOS
- Android
- iOS

La pagina pubblica di Prysm descrive l'app come un messenger Tor basato su Flutter e cross-platform, ancora in sviluppo attivo.

## Build

È necessario avere un toolchain Flutter funzionante.

### Dipendenze Linux

Per il supporto tray su Linux, installare le librerie di sviluppo AppIndicator:

- Arch: `libayatana-appindicator`
- Ubuntu/Debian: `libayatana-appindicator3-dev`
- Ubuntu/Debian più vecchi: `libappindicator3-dev`

Su GNOME, l'icona tray potrebbe richiedere l'[estensione AppIndicator](https://extensions.gnome.org/extension/615/appindicator-support/).

### Comandi di build

```bash
flutter build linux
flutter build windows
flutter build macos
```

Su desktop, il binario Tor viene scaricato automaticamente al primo avvio.

## Rilascio

Ultimo rilascio: [v0.2.0](https://github.com/xmreur/prysm/releases)

## Note

Questo è ancora un prototipo.

Il modello di base è presente, ma il trasporto, lo storage e alcune parti di UX/sicurezza sono ancora in evoluzione. Sono previsti breaking changes mentre gli interni si stabilizzano.

## Note di sicurezza

Questo progetto non è stato auditato. Il design crittografico e l'implementazione del trasporto non sono ancora pensati per casi d'uso ad alto rischio. Consideralo come software sperimentale.

## Supporto

Se vuoi supportare lo sviluppo, le donazioni sono benvenute.

- BTC: `bc1qev0zu7rnske4ee7as0t4tyh56uv6v0ga62wx8r`
- SOL: `2S6tZNNUH5sPp9PqszQ4XK4MN44SvLCkTwNuCVvRvtEP`
- ETH: `0x2934955fe95059ea470E0B81519BA59432eFe77a`
- XRP: `rHfoRsLjXrbAqxa7nJcXz6XdxDZm8M3sJT`
- XMR: `47ndq7fCdW9jTGKtXafwMgDJjxAw3cnWwjR6eq31pfXXKfqNHXq5w4B2D49oTKnTHGCRCgcU6D24oiyUD8Ha7iEJLCPGJsC`
- TON: `UQDEeapruNlAmSt9j4J9CNiuasJbF3OlCxzTZPJiq6hzKOFu`
- LTC: `ltc1qnsp6alkn2gzd4vpekya05l2caa3aqfmk9m7882`

## Roadmap

- Implementare relay / proxy forwarding
- Aggiungere riconoscimenti di consegna oltre "POST succeeded"
- Migliorare la latenza di startup di Tor su mobile
- Pulire il protocollo di trasporto e la gestione degli errori
- Aggiungere documentazione più esplicita del threat model