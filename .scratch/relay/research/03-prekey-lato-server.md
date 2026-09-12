# Prekey X3DH serviti da un'entità non fidata (Relay come prekey server)

## 1. Prekey server in X3DH: cosa custodisce, firma, menzogne, non-garanzie

- Custodisce: `IKB`, `SPKB`, `Sig(IKB, Encode(SPKB))`, set di `OPKB` (X3DH §3.2, https://signal.org/docs/specifications/x3dh/#publishing-keys). Il server consegna il "prekey bundle" e **cancella l'OTK servito**; se esauriti, bundle senza OTK (X3DH §3.3, https://signal.org/docs/specifications/x3dh/#sending-the-initial-message).
- La firma copre solo `SPKB` (e in PQXDH anche ogni `PQOPKB`/`PQSPKB` con `IKB`: PQXDH §3.2, https://signal.org/docs/specifications/pqxdh/#publishing-keys). Gli OTK classici **non sono firmati**: l'autenticazione resta sui DH1/DH2, la firma serve contro il "weak forward secrecy attack" (X3DH §4.5, https://signal.org/docs/specifications/x3dh/#signatures).
- Menzogne possibili: rifiuto di consegna/DoS; consegna di prekey forgiati (neutralizzata se Alice verifica la firma e ha autenticato IKB, §4.1+§4.5); **rifiuto di consegnare OTK** pur avendoli.
- Non-garanzie esplicite: con IKB autenticato, "the only additional attack available to the server is to refuse to hand out one-time prekeys, causing forward secrecy for SK to depend on the signed prekey's lifetime" (X3DH §4.7, https://signal.org/docs/specifications/x3dh/#server-trust). Il server è quindi **non fidato per disponibilità/FS-forte, fidato-zero per riservatezza** (non vede SK).

## 2. Pool OTK: consumo, esaurimento, signed/last-resort, proprietà persa

- Consumo contato dal **server** (consegna una volta e cancella, §3.3) + cancellazione **locale** del privato OTK dal destinatario alla ricezione (§3.4 "Bob deletes any one-time prekey private key").
- Esaurimento: handshake valido senza OTK, salta DH4 (`SK = KDF(DH1||DH2||DH3)`), §3.3.
- Last-resort: concetto formalizzato in PQXDH per il lato PQ — `PQSPKB` riusabile "only used when one-time pqkem prekeys are not available" (PQXDH §2.5, https://signal.org/docs/specifications/pqxdh/#post-quantum-key-encapsulation-keys); il server preferisce `PQOPKB` e ripiega su `PQSPKB` (§3.3). L'analogo classico è il **signed prekey da solo**: funziona ma...
- Proprietà persa (citare): "If one-time prekeys were not used... compromise of the private keys for IKB and SPKB from that protocol run would compromise the SK calculated earlier. Frequent replacement of signed prekeys mitigates this" (X3DH §4.6, https://signal.org/docs/specifications/x3dh/#key-compromise). Quindi: **forward secrecy dell'handshake degrada da "sicura alla cancellazione OTK" a "sicura per la lifetime di SPK"**. Replay: senza OTK il messaggio iniziale "may be replayed to Bob and he will accept it" (§4.2) con derivazione dello stesso SK (§4.3) — il Double Ratchet a valle deve randomizzare prima che Bob invii dati (§4.3 MUST).

## 3. Riuso di un OTK: cosa si perde, rilevabilità

- Se il server serve lo stesso OTK a due Alice: DH4 (`DH(EKA, OPKB)`) è calcolabile da chiunque osservi i due handshake solo se... no: EKA sono diversi quindi SK restano diversi. Ciò che si perde: **la garanzia che la compromissione futura di IKB+SPK non comprometta SK** — l'attaccante che registra entrambi gli handshake e poi compromette OPK-privato+IKB+SPK decifra entrambi (stesso ragionamento di §4.6, primo bullet: la FS-forte richiede OTK usato-una-volta-e-cancellato). Inoltre il replay del *medesimo* messaggio iniziale produce lo stesso SK (§4.3) con rischio key-reuse catastrofico se Bob non ratcheta prima di rispondere.
- Deniability: X3DH §4.4 dà deniability offline, non online ("If either party is collaborating... able to provide proof"); il riuso OTK non crea una *publishable proof* nuova oltre a quella intrinseca del setting asincrono. [Opinione: il danno del riuso è su FS, non un collasso della deniability.]
- Rilevabilità dal destinatario: **sì, al Pickup** — il bundle iniziale cita "identifiers stating which of Bob's prekeys Alice used" (§3.3); Bob carica i privati via identifier (§3.4). Due messaggi con stesso OTK-id = riuso rilevato (può mantenere blacklist dei messaggi osservati, §4.2 "maintaining a blacklist"). Se il server *omette* l'OTK invece di riusarlo, è indistinguibile dall'esaurimento legittimo (downgrade silenzioso): rilevabile solo statisticamente (contatore OTK mai consumato / frequenza bundle-senza-OTK).

## 4. Svuotamento malizioso del pool (drain) e contromisure documentate

- La spec lo prevede esplicitamente: "This reduction in initial forward secrecy could also happen if one party maliciously drains another party's one-time prekeys, so the server should attempt to prevent this, e.g. with rate limits on fetching prekey bundles" (X3DH §4.7).
- Contromisure documentate: rate limit sul fetch (§4.7); rifornimento proattivo ("server informs Bob that the store is getting low", §3.2); rotazione frequente di SPK per mitigare la finestra FS-debole (§4.6); blacklist/replace rapido SPK contro replay (§4.2); Double Ratchet a valle che rirandomizza subito SK (§4.3, §4.2).
- [Opinione: per Prysm Relay — rate limit per senderId, pool 16 con TTL 30' già esistente, soglia di rifornimento, firma del bundle con timestamp/monotono per rendere il drain auditabile.]

## 5. Binding bundle-identità e lifetime cache

- Binding: firma `Sig(IKB, Encode(SPKB))` verificata da Alice con abort su fallimento (§3.3); PQXDH estende la firma a ogni chiave PQ (§3.3 "Alice verifies the signatures on the prekeys"). AD = `Encode(IKA)||Encode(IKB)` lega il ciphertext alle identità (§3.3). Contro misbinding resta l'autenticazione out-of-band dei fingerprint (§4.1) e identificatori aggiuntivi in AD (§4.8, https://signal.org/docs/specifications/x3dh/#identity-binding).
- Lifetime cache: la spec non dà un TTL numerico al bundle; dà il principio: SPK ruotato "once a week, or once a month", vecchio privato tenuto "for some period of time" poi cancellato per FS (§3.2). PQXDH §4.6: la compromissione di IKB+SPK+PQSPK compromette SK finché non ruotati. [Inferenza: bundle cachabile solo entro la rotazione SPK; per Prysm, TTL cache ≤ rotazione SPK, p.es. giorni, e il Relay deve servire l'SPK corrente firmato.]
- Nota libsignal (fonte secondaria, non verificata sul sorgente: changelog `libsignal` Dart 7.0.2 su `markKyberPreKeyUsed` con signed-prekey-ID + base key per bookkeeping last-resort): indica che l'implementazione distingue OTK vs last-resort via ID e traccia l'uso contro i replay — coerente con "Bob deletes one-time...; last-resort retained" di PQXDH §3.4/§2.5. Da verificare su `signalapp/libsignal` prima di citarlo come fatto.

## Applicabilità a Prysm

**Importiamo:**
- Modello di minaccia X3DH §4.7 come baseline: Relay non fidato per FS-forte/disponibilità, zero-impatto su riservatezza se firma verificata + IKB autenticato.
- Bundle Relay = IKB + SPK + firma + OTK-opzionale, con identifier per chiave (rilevabilità riuso al Pickup); handshake senza OTK valido (salta DH4) — compatibile con `prekey_bundle.dart` (OTK nullable) e `ratchet_service.dart:212-216` (serve almeno il bundle).
- Rate limit fetch + rifornimento + rotazione SPK + ratchet immediato post-pickup (§§4.2/4.3/4.6/4.7).
- Consumo resta **locale al destinatario** (commit al Pickup), coerente con `lookup/commit/release` + TTL 30'.

**Scartiamo:**
- PQ/Kyber last-resort ora (Prysm è X25519-only): il "last-resort" è semplicemente SPK-senza-OTK con FS-degradata, non una nuova primitiva.
- Cache lunghe del bundle oltre la rotazione SPK; persistenza del bundle del peer lato mittente (resta vietata: il mittente usa-e-getta, come oggi).

**Risposta secca:** **Sì, un Relay può servire un bundle senza che l'utente perda garanzie, a condizioni:** (1) bundle firmato con IKB e firma verificata dal mittente con IKB autenticato OOB; (2) OTK mai riusato — uno per bundle, altrimenti FS-forte persa; (3) fallback senza-OTK ammesso solo come degradazione dichiarata (FS legata a lifetime SPK + anti-replay/ratchet immediato); (4) rate limit + rifornimento contro il drain; (5) consumo autoritativo al Pickup dal destinatario con rilevamento riuso via key-id.

**Abusi di un Relay ostile (rilevabilità al Pickup):**
| Abuso | Effetto | Rilevabile al Pickup? |
|---|---|---|
| Rifiuto consegna / DoS | niente sessione | Sì (assenza) |
| OTK forgiato non firmato | handshake con DH4 ignoto al destinatario → decrypt fallisce | Sì (decrypt fallisce, §3.4 abort) |
| SPK forgiato | firma non verifica → Alice aborta prima di inviare | Sì lato mittente (§3.3) |
| Riuso stesso OTK a 2 mittenti | FS-forte persa per entrambe le sessioni | Sì (stesso OTK-id in 2 initial) |
| Omissione OTK pur disponibile (downgrade) | FS legata a SPK-lifetime | No puntualmente; sì statisticamente |
| Drain del pool (N fetch) | forza fallback senza-OTK | Sì statisticamente (tasso fetch anomalo) |
| Bundle stantio (SPK vecchio) | finestra FS-debole allungata | Sì (SPK-id/timestamp obsoleto) |
| Replay di un initial | stesso SK, doppi messaggi | Sì (blacklist, §4.2) |
