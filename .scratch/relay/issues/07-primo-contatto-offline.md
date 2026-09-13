# Primo contatto con un peer offline: profilo e prekey serviti dal Relay

Type: grilling
Status: resolved
Blocked by: 01, 03

## Question

Un Relay risolve la consegna, non l'apertura della sessione: oggi, senza sessione e senza prekey
bundle, il mittente **non puo' cifrare nulla**. Tre strade, da scegliere:

1. **Il Relay serve l'identita' e i prekey per conto dell'utente**: snapshot di profilo firmato
   dall'Identity + pool di one-time prekey caricati dall'utente, con consumo marcato lato Relay e
   riconciliato al Pickup. Cosa fa il client quando scopre che un OTK e' stato dato via? Cosa accade
   se il pool si svuota mentre l'utente e' offline per giorni?
2. **Il Relay serve solo il signed prekey** (senza OTK): sessione apribile sempre, forward secrecy
   ridotta per il primo messaggio. Accettabile e documentabile?
3. **Il Relay non serve nulla**: i Relay funzionano solo fra peer che si sono gia' parlati almeno una
   volta, e lo scriviamo come limite in chiaro nella documentazione utente.

## Context

- `RatchetService.encryptBytes`: `throw StateError('Missing prekey bundle')` senza sessione e senza
  bundle (`lib/crypto/ratchet/ratchet_service.dart:212-216`).
- Il bundle arriva solo da un fetch live di `/profile` del destinatario
  (`lib/services/peer_identity_resolver.dart:84-98`) e **non viene persistito** (`:113-128` salva solo
  `identityJson` e `ratchetScheme`).
- Lato destinatario il consumo OTK e' locale: `commitOneTimePreKeyConsumption` /
  `releaseOneTimePreKey`, prenotazione con TTL 30 minuti
  (`lib/crypto/ratchet/prekey_bundle.dart:44`, `lib/crypto/ratchet/ratchet_service.dart:350-361`).
  Un consumo deciso dal Relay e' uno stato che vive **fuori** dal dispositivo: va riconciliato.
- Senza OTK l'X3DH salta DH4 e resta valido (`sharedSecretAsInitiator`): il degrado esiste gia' come
  percorso di codice.
- Il primo messaggio dopo lo scambio contatto porta l'handshake agganciato all'envelope
  (`ratchet_service.dart:250-252`): il Relay lo vedrebbe passare, non e' un dato nuovo per lui.

## Done when

- Strada scelta, con il costo di sicurezza scritto in chiaro (e ADR se e' irreversibile).
- Se il Relay serve materiale: deciso chi firma lo snapshot, quanto vale, come si ricarica il pool,
  come si riconcilia il consumo al Pickup, cosa fa il client con un OTK bruciato.
- Se il Relay non serve materiale: il limite e' scritto nella nebbia della documentazione utente come
  requisito ("aggiungi il contatto quando siete entrambi online, poi il Relay basta").

## Answer

Deciso: **(3) il Relay non serve prekey nella v1**, e il limite si scrive in chiaro nella
documentazione utente. Spec §8.

Perche' non la (1): la ricerca ([prekey X3DH serviti da un'entita' non
fidata](03-research-prekey-lato-server.md)) dice che si *puo'* fare in sicurezza, ma solo con cinque
condizioni simultanee — firma verificata sul signed prekey corrente, nessun riuso di OTK, fallback
senza OTK dichiarato come degrado, rate limit sul fetch piu' rifornimento, consumo autoritativo
riconciliato al Pickup. Sono un endpoint family in piu', uno stato di consumo che vive **fuori** dal
dispositivo (oggi `commitOneTimePreKeyConsumption` e' locale) e una riconciliazione da progettare:
troppo per la v1, e ortogonale al problema che i Relay risolvono davvero.

Perche' il limite e' accettabile: aggiungere un contatto **oggi richiede gia' entrambi online**
(`ContactAddService` fetcha `/profile` su Tor), e lo stesso fetch e' quello che porta
l'Advertisement. Quindi la regola per l'utente e' una frase: *"scambiatevi il contatto una volta
mentre siete entrambi online; da quel momento il Relay copre tutto"*. E' esattamente la proprieta'
di Briar Mailbox, che non gestisce il primo contatto affatto.

In nebbia, con la forma che avrebbe: snapshot di profilo firmato + pool OTK caricati dall'utente,
consumo marcato dal Relay e riconciliato al Pickup, con degrado dichiarato a signed-prekey-only
quando il pool e' vuoto.
