# Prior art: prekey X3DH serviti da un'entita' non fidata

Type: research
Status: resolved

## Question

Se un Relay serve il materiale per aprire una sessione al posto dell'utente offline, cosa si rompe?
Da accertare sulle fonti primarie (spec X3DH e Double Ratchet di Signal, libsignal, spec SimpleX,
paper e analisi formali):

1. Come e' pensato il **prekey server** in X3DH: cosa custodisce, cosa firma, cosa puo' mentire.
2. **Pool di one-time prekey**: chi conta il consumo, cosa accade all'esaurimento, cos'e' il
   *last-resort / signed prekey* e quale proprieta' di sicurezza si perde usandolo.
3. **Riuso di un OTK**: cosa perde esattamente la forward secrecy / deniability se il server serve lo
   stesso OTK a due mittenti, e come lo rileva il destinatario.
4. **Svuotamento malizioso del pool** (un mittente che chiede N bundle per forzare il downgrade):
   contromisure documentate.
5. Cosa dicono le fonti sul **binding fra bundle e identita'** (firma sul prekey) e su quanto a lungo
   un bundle puo' restare valido in cache.

## Context

Prysm ha gia' l'impianto: `PrekeyBundle` con pool da 16, prenotazione con TTL 30 minuti, e
`lookup/commit/release` (`lib/crypto/ratchet/prekey_bundle.dart:44`, `:104-107`, `:373-389`). Il
consumo e' committato **localmente dal destinatario**; il bundle del peer **non viene mai persistito**
dal mittente (`lib/services/peer_identity_resolver.dart:113-128`). Senza bundle e senza sessione,
`RatchetService.encryptBytes` lancia `StateError('Missing prekey bundle')` (`:212-216`).

## Done when

- Findings in `.scratch/relay/research/03-prekey-lato-server.md`, con citazioni puntuali (sezione
  della spec / file e riga di libsignal).
- Risposta secca a: "il Relay puo' servire un bundle senza che l'utente perda garanzie?" con le
  condizioni necessarie.
- Elenco dei modi in cui un Relay ostile puo' abusare del ruolo di prekey server, e quali sono
  rilevabili dal destinatario al momento del Pickup.

## Answer

1. Il prekey server custodisce IKB+SPK+firma+OTK, serve un OTK cancellandolo (X3DH §3.2-3.3); firma solo SPK, OTK non firmati (§4.5); con IKB autenticato l'unico attacco residuo è rifiutare gli OTK, degradando la FS alla lifetime di SPK (§4.7).
2. Il consumo lo conta il server (consegna-e-cancella) + il destinatario cancella il privato alla ricezione (§3.3/§3.4); esaurito → handshake valido senza OTK (salta DH4); il last-resort (PQXDH §2.5/§3.3) è riusabile e costa la FS-forte: compromissione futura di IKB+SPK compromette SK (§4.6).
3. Riuso OTK: SK restano diversi (EKA diversi) ma cade la FS-forte per entrambe le sessioni; il replay dello stesso initial deriva lo stesso SK con rischio key-reuse (§4.3); deniability offline invariata (§4.4). Rilevabile: gli initial citano i key-id (§3.3/§3.4), due initial con stesso OTK-id = riuso; blacklist in §4.2.
4. Il drain è previsto in §4.7: contromisure = rate limit sul fetch, rifornimento su soglia (§3.2), rotazione SPK (§4.6), ratchet immediato (§4.2/§4.3).
5. Binding via Sig(IKB,Encode(SPK)) con abort su fallimento + AD=IKA||IKB (§3.3), fingerprint OOB (§4.1/§4.8); nessun TTL numerico in spec, rotazione SPK settimanale/mensile (§3.2) = tetto implicito di cache.
**Risposta secca: sì, il Relay può servire bundle senza perdita di garanzie se: firma IKB verificata su SPK corrente, un OTK mai riusato, fallback senza-OTK dichiarato come degradato, rate-limit+rifornimento, consumo autoritativo al Pickup.**
Findings: `../research/03-prekey-lato-server.md`
