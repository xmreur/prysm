# Persistenza e identità di default

Type: grilling
Status: resolved
Blocked by: 02, 03

## Question

Decisione di default pericoloso: oggi `--no-persist` è il default e `docker rm` porta con sé identità + onion, invalidando ogni Contract firmato — gli operatori devono ri-accoppiare tutti. Quale default e quale automazione impediscono la perdita accidentale?

Da decidere con grilling (HITL — è il default che distrugge dati se sbagliato):

1. Flip del default a persistente (volumi nominati o path host) sì o no, e per entrambi i percorsi (container del ticket immagine, nativo del ticket systemd)?
2. Layout canonico: dove vivono `identity.json` (0600), chiave HS, `config.json`, e chi li crea con quali permessi al primo giro?
3. Regole di rewrite onion/port/admission dello script (oggi riscrive e riavvia/SIGHUPpa): restano implicite o diventano esplicite con conferma?
4. Backup automatico dei due segreti irreplaceabili al primo provisioning (promemoria + comando pronto vs timer automatico) e procedura di ritiro sicuro (annuncio, `admission: closed`, drain `items=0`, cancellazione)?

## Context

- Risoluzioni di [Immagine prebuilt pubblicata vs compilazione ogni volta](02-immagine-prebuilt-pubblicata.md) e [Installazione nativa systemd senza Docker su host dedicato](03-installazione-nativa-systemd.md): il default vive dentro il percorso scelto lì.
- `tool/CREATE-RELAY.md` (sezione Persistence: cosa sopravvive a cosa) e README `Back up and restore` + `Decommission`: i fatti, non le opinioni.
- Fatto duro: identità persa = ogni Contract muore (client rifiuta qualunque altro fingerprint, re-pairing da zero); onion perso = indirizzo morto (i client hanno memorizzato quello vecchio).

## Done when

- Default di persistenza per percorso + layout + permessi scritti nella risoluzione.
- Comportamento rewrite e automazione backup/ritiro decisi, con motivo.
- Criterio di accettazione: `docker rm` / reinstallazione accidentale non invalida più un relay attivo senza un'esplicita azione di ritiro.

## Resolution

Deciso con l'utente: **persistenza attiva di default** su entrambi i percorsi —
identità, onion e tenant sopravvivono a `docker rm`/reinstallazione; la cancellazione
totale richiede un'azione esplicita di ritiro. Layout, permessi e automazione
backup/ritiro: secondo README (`Back up and restore`, `Decommission`) e CREATE-RELAY.md,
da applicare in esecuzione.
