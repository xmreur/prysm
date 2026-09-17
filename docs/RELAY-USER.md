# Relay user guide

A Relay receives messages for you while you are offline and hands them to you
when you come back. It never sends on your behalf and it cannot read your
messages: everything it holds is sealed so only your device can open it.

Someone has to host a Relay: yourself on a second computer or a VPS, a friend,
or a community operator. If you want to run one, the operator manual is
`packages/prysm_relay_server/README.md`. How it all works under the hood is
described in [docs/RELAY.md](RELAY.md).

## Before you start

You need two things: a Relay that is already running, and the one-time setup
token its operator gives you. Ask the operator for both.

One more condition (a v1 limit): you and each contact must already have added
each other once while you were both online. The first exchange of contact
details cannot go through a Relay yet; see
[docs/RELAY.md#v1-limits](RELAY.md#v1-limits) for why.

## Pair with a Relay

The usual way needs a single thing from your operator: a **pairing link**
(plain text) or its QR code. The link already carries the Relay's address,
its fingerprint, and your one-time setup token.

1. Open `Settings`, scroll to the `Network` section, and tap `Relay`
   (`Receive messages while you are offline`). If you never paired, the row
   reads `Not paired`.
2. Tap `Paste pairing link` and paste the link. The app fills in `Relay
   address` and `Setup token`, confirms with `Pairing link applied`, and
   reads the Relay's info on its own. (On Android you can tap `Scan pairing
   QR code` instead and point the camera at the operator's QR code. Pasting
   the link straight into `Relay address` works too: the app recognizes it
   and treats it the same way.)
3. Read what comes back before you accept anything: the `Private` or
   `Public` chip beside the fingerprint, who may join under `New accounts`
   (`Open`, `Invite only` or `Closed`), the promised limits (`Max message
   size`, `Keeps messages`, `Max messages per contact`,
   `Max total storage`), and the operator's `Terms` if there are any. You
   do not need to compare the fingerprint yourself: the app compares it
   with the one in the link and writes `Fingerprint matches the pairing
   link.` underneath.
4. If everything looks right, tap `Pair with this relay`. If the listing's
   proof does not check out, the app blocks Pairing and says so: do not
   pair with that Relay.

If the fingerprint in the listing differs from the one in the link, the app
shows `This relay's fingerprint does not match the pairing link. Pairing is
blocked: do not pair with this relay.` and disables `Pair with this relay`,
exactly as for a bad signature. Stop: do not pair, and contact the operator
through another channel.

Without a link you can still pair by hand: paste the Relay's address into
`Relay address` and the token into `Setup token`, tap `Read relay info`,
and compare the `Fingerprint` yourself with what the operator told you
through another channel — it is the one value that proves the Relay is the
one you meant — before tapping `Pair with this relay`.

The link contains your setup token: treat it like a one-time password and
do not forward it to anyone.

After Pairing, three things are true: your Contract with the Relay is stored
on this device, your Mailbox on the Relay exists, and your contacts learn your
Advertisement the next time you exchange profiles, so their apps know where
you can be reached while you are offline.

The row itself shows `Not paired` until you pair; afterwards it shows your
Relay's address, so you can tell at a glance that Pairing is in place.

## Everyday use

Almost nothing changes. A message your Relay accepts still shows as `sent` on
the sender's side, exactly as today: there is no new tick, and deliberately no
delivery receipt, because a receipt would reveal the moment you come back
online.

Pickup is automatic: when the app starts or finds its connection again, it
collects whatever the Relay held for you. If you do not want to wait, open the
Relay screen and tap `Pick up now`; the screen also shows `Last pickup` so you
can see when the last collection happened and whether it brought anything.

The same screen keeps you informed about space. `Stored on the relay` tells
you how many messages are waiting and when the oldest one expires; `Your plan
on this relay` repeats the limits you accepted when Pairing, so a full Relay
never comes as a surprise.
Two v1 limits still apply: talking to someone for the very first time needs
you both online at once, and large attachments are never stored on a Relay,
they wait until you are both online together.

## Manage your mailboxes

You have one Mailbox per contact on the Relay. The `Contacts on this relay`
list shows one row per contact — identified by that contact's Prysm ID, or by
the opaque address itself until the app has matched it to a contact — with how
many messages are waiting and how much space they take. Rows appear once
contacts start using your Relay; while
nobody does, the list says `No contact uses this relay yet. Addresses appear
here once contacts send to your relay.`

Each row has a `Revoke` button. Revoking asks `Revoke this address?` and warns
that the contact will no longer be able to leave messages on the Relay, and
that messages already stored there are deleted. After a revocation that
contact can only reach you directly, when you are both online. The Relay never
knew whose address that was: it only ever saw an opaque address, never a name.

## Turn it off / unpair

The `Use this relay` switch (`Store incoming messages here while you are
offline`) pauses everything without deleting anything: while it is off, nobody
can deposit for you and no Pickup happens, but your Contract, Mailboxes and
stored messages stay where they are. Flip it back on to resume.

`Unpair relay` is different and permanent. It asks `Unpair this relay?` and,
once you confirm with `Unpair and delete`, your account on the Relay is gone:
Mailboxes and every message not yet collected are deleted and cannot be
recovered. Your chats on this device are not affected.
The app confirms with `Relay unpaired`.

## When something goes wrong

The Relay screen shows a plain sentence instead of a technical error, and it
tells you whether retrying is worth it (`Worth retrying.` or
`Retrying will not help.`). Messages affected by a retryable problem stay in
the sender's local queue, so nothing is lost.

| Symptom | What it means | What to do |
|---|---|---|
| `This setup token is invalid or already used. Ask the relay operator for a new one.` | The token is wrong, expired, or was already spent. | Ask the operator for a fresh token. Retrying the old one will not help. |
| `This relay is not accepting new accounts right now.` | The Relay is closed to new arrivals — including a `Private` Relay that already serves someone else (verified live). | Ask the operator, or pick another Relay. Retrying will not help. |
| `Prysm is not paired with a relay. Pair again to continue.` | The Pairing is gone. | Pair again from scratch. |
| `This contact's box on the relay is full. It accepts new messages once older ones expire or are picked up.` | One Mailbox hit its per-contact limit. | Pick up your messages, or wait for old ones to expire. Worth retrying. |
| `Your space on the relay is full. Pick up your messages or wait for older ones to expire.` | Your whole share on the Relay is full. | Same: collect your messages or wait. Worth retrying. |
| `The relay is busy. Nothing is lost — it is worth trying again.` | You hit the Relay's rate limit. | Wait a little and try again. |
| `Your device clock looks wrong, so the relay refused the request. Check the date and time, then try again.` | Your clock drifted too far. | Fix the date and time, then retry. |
| `The relay rejected our signature. Pair again from scratch.` | Your proof of identity was refused. | Pair again from scratch. |
| `The relay hit an internal error. Nothing is lost — it is worth trying again.` | Something broke on the Relay's side. | Try again; tell the operator if it persists. |
| `That is not a valid pairing link.` | The pasted or scanned text is not a pairing link. | Paste the full link exactly as the operator gave it to you, without adding or removing anything. |
| `This relay's fingerprint does not match the pairing link. Pairing is blocked: do not pair with this relay.` | The Relay's listing does not match the link you pasted or scanned. | Stop. Do not pair; contact the operator through another channel. |
| `Something went wrong ({code}).` plus a connection failure | The Relay is unreachable over Tor. | Check your connection and try again later. |
| `Loading relay status…` never finishes, then `Still connecting: the first contact with a new relay can take up to a minute.` | Normal on the first try: the Tor circuit to a new Relay is cold and the first request can take longer than the first wait (measured 40 s against a 30 s budget), so the app retries once on its own with a longer budget. | Wait for the second try to finish; it usually succeeds. If it still fails, check your connection and try again later. Nothing is wrong with your Relay, and Pickup keeps retrying on its own. |

## What your Relay operator can see

An operator sees that a message arrived for your account (Pickup is
authenticated, so your Relay account is never anonymous to them), at which
per-contact address, how big the sealed message was, and when it arrived or
was collected. They never see who sent it, the text, the message type, group
names or file names, and they cannot tell which of your contacts an address
belongs to. The full picture is in
[docs/RELAY.md#threat-model](RELAY.md#threat-model).
