# Prysm

[🇬🇧 English](README.md) | [🇮🇹 Italiano](README.it.md)

<p align="center">
  <img src="https://cdn.discordapp.com/icons/1420770528691617928/e685f1b4b88adc1b6a8da534633b7fca.png?size=512" width="320" alt="Logo Prysm">
</p>

Prysm è un messenger P2P basato su Tor, costruito con Flutter.

Non c'è nessun server centrale. Ogni client espone il proprio servizio hidden Tor, riceve messaggi direttamente sul suo indirizzo `.onion` e invia messaggi in uscita tramite Tor. Se un peer è offline, i messaggi restano in una coda locale e vengono riprovati più tardi.

## Panoramica

Su desktop, Tor viene avviato come processo child. Su Android e iOS viene avviato tramite un servizio nativo. L'app espone anche un server HTTP locale con `shelf`, in ascolto sulla porta `12345`, che Tor rende disponibile come `your-address.onion:80`. I messaggi in uscita sono inviati tramite il proxy SOCKS5 di Tor verso `peer-address.onion:80/message`.

Non ci sono server relay al momento. Le impostazioni relay esistono nell'UI, ma sono placeholder e non implementate.

## Flusso dei messaggi

Se entrambi i peer sono online, i messaggi arrivano in genere entro pochi secondi.

Se il destinatario è offline o irraggiungibile, Prysm salva il messaggio localmente in SQLite e riprova con backoff esponenziale. Questo permette all'app di comportarsi come un messenger asincrono senza infrastruttura centralizzata.

## Crittografia

Dalla versione 0.4.0 in poi, Prysm usa la **Crypto v2**: chiavi di identità Curve25519, formati wire solo-AEAD, protezione passphrase con Argon2id e sessioni Double Ratchet per la forward secrecy nelle chat 1:1. L'aggiornamento da 0.2.x richiede una migrazione pulita (esportare se serve, cancellare, riconfigurare).

### Identità

- Chiave di firma **Ed25519** e chiave di accordo **X25519**, generate localmente.
- Chiave privata crittografata a riposo con **AES-256-GCM**.
- Chiave di crittografia derivata da una **passphrase** (minimo 12 caratteri) con **Argon2id** (64 MiB, 3 iterazioni).
- Chiavi pubbliche pubblicate su `/profile` come JSON versionato (`crypto: v2`). I QR code includono un **fingerprint** dell'identità per la verifica fuori banda.

Gli indirizzi onion Tor sono separati dalle chiavi di identità di Prysm.

### Messaggi diretti (1:1)

- **Double Ratchet** (`ratchet-1`) con bundle prekey in stile X3DH per il bootstrap della sessione.
- **AES-256-GCM** per messaggio con chiavi derivate dalla catena (forward secrecy).
- I file usano X25519 effimero + HKDF + AES-GCM (`dh-aead-1` / `file-aead-1`).

### Messaggi di gruppo

- Crittografia **sender-key** (`group-sender-1`): chiavi per messaggio derivate dalla chiave di epoch del gruppo.
- Chiave di epoch distribuita tramite payload di controllo cifrati con X25519.
- L'epoch ruota quando i membri vengono rimossi.

### Trasporto

- Il server locale si lega a **tutte le interfacce IPv4** (`InternetAddress.anyIPv4`) così Tor può raggiungere la porta del servizio hidden.
- Il server si avvia all'apertura dell'app.

### Backup

- Formato backup **v2**: Argon2id + AES-GCM. I backup v1 non possono essere ripristinati in v2.

## Implementato

- Messaggistica 1:1 crittografata
- Chiamate vocali con cronologia
- Allegati: immagini, file, audio, messaggi vocali
- Chat di gruppo (fino a 5 membri) con flusso di invito, rotazione chiave e rimozione membri
- Reazioni emoji
- Modifica, cancellazione e messaggi usa-e-getta
- Ricevute di lettura con toggle
- Anteprima inline per PDF, `.docx`, `.xlsx`, immagini, audio e video
- Coda offline con riprova
- Scambio contatti tramite QR code o indirizzo `.onion` in base58
- Integrazione con tray su desktop
- Modalità panico con wipe o sessione decoy
- Pin e archiviazione delle conversazioni
- Polling batteria-aware
- Anteprime dei link
- Indicatori di digitazione
- Messaggi programmati (accodati e consegnati all'orario scelto)
- Chat con te stesso
- Finestre chat separate su desktop
- Contatti bloccati
- Backup crittografati
- Sblocco con biometrico e PIN
- Auto-aggiornamento integrato (APK Android e installer desktop)

## Non implementato

- Relay / proxy forwarding
  Le impostazioni esistono nell'UI, ma non c'è nessun backend relay al momento.

## Piattaforme

Costruito con Flutter. Target supportati:
- Linux
- Windows
- macOS
- Android
- iOS

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

Ultimo rilascio: [v0.6.0](https://github.com/xmreur/prysm/releases)

## Note

Questo è ancora un prototipo.

Il modello di base è presente, ma trasporto, storage e alcune parti di UX e sicurezza sono ancora in evoluzione. Sono previsti breaking change mentre gli interni si stabilizzano.

## Supporto

Se vuoi supportare lo sviluppo, le donazioni sono benvenute.

- BTC: `bc1qev0zu7rnske4ee7as0t4tyh56uv6v0ga62wx8r`
- SOL: `2S6tZNNUH5sPp9PqszQ4XK4MN44SvLCkTwNuCVvRvtEP`
- ETH: `0x2934955fe95059ea470E0B81519BA59432eFe77a`
- XRP: `rHfoRsLjXrbAqxa7nJcXz6XdxDZm8M3sJT`
- XMR: `47ndq7fCdW9jTGKtXafwMgDJjxAw3cnWwjR6eq31pfXXKfqNHXq5w4B2D49oTKnTHGCRCgcU6D24oiyUD8Ha7iEJLCPGJsC`
- TON: `UQDEeapruNlAmSt9j4J9CNiuasJbF3OlCxzTZPJiq6hzKOFu`
- LTC: `ltc1qnsp6alkn2gzd4vpekya05l2caa3aqfmk9m7882`
