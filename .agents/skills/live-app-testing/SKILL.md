---
name: live-app-testing
description: "Use when you need to prove UI<->state integration on the real, running Prysm app — Linux desktop or Android — : screens render what the stores contain, taps and long presses land, routes open and close. Proves the app's own wiring end to end. It does NOT prove pixels by itself, does NOT prove the compositor's input path, and does NOT run in CI."
---

# Live App Testing

Drive the real Prysm app with `tool/live/prysmlab` — observation (Dart VM Service widget
trees), control (in-app pointer events via `evaluate`), and data injection (HTTP against the
app's loopback server). Two platforms, one CLI:

| | command | what runs |
|---|---|---|
| Linux desktop | `prysmlab …` (default) | the GTK app under Xvfb, private D-Bus session + keyring |
| Android | `prysmlab -p android …` | the real APK on an in-container x86_64 emulator (KVM), AVD `pixel_5` |

Everything downstream of the VM Service is identical on both; only the lifecycle differs.
**Pick the platform the report came from.** A layout or gesture complaint from a phone is not
refuted by the desktop build: `defaultTargetPlatform` changes the gesture branch that runs
(on Linux a long press inside a focused field moves the caret, on Android it selects a word),
and the two builds do not even render the same navigation surfaces.
The Android lab has its own handoff: `HANDOFF-android-lab.md`.

## When to use it — and when not

Use it when the defect lives in the integration between UI and state: a screen that does not
show what the DB holds, a tap that does not reach its handler, a route that does not open or
close, a store whose change the UI never reflects. That is where this method found real bugs.

Do NOT use it for:

- **Pixels, by default.** The dump is text: what is in the tree, not how it looks.
  `prysmlab shot` writes a PNG (Xvfb framebuffer on Linux, `adb exec-out screencap` on
  Android) — and on a harness with an image-inspection tool that PNG *is* readable, which is
  how the selection handles were caught pointing the wrong way:
  `SHOT=$(prysmlab -p android shot | tail -1) && docker cp prysm-lab-android:"$SHOT" /tmp/x.png`,
  then inspect `/tmp/x.png`. Use it for **geometry and presence**, never for values: the
  reading is a description, not a measurement, and it has already mistaken the app's own light
  theme for "a Material toolbar" and a system dialog's scrim for "a dark app". For colours,
  read the live token with an `eval`; for rects, read the `RenderBox` with an `eval`.
- **The compositor's input path.** `prysmlab tap` delivers `PointerDown/UpEvent` through
  Flutter's own hit test and gesture recognizers. It proves the app's wiring, not that a real
  click (window focus, display scaling, layered windows) arrives the same way.
- **Regression.** It is a repeatable manual proof, not a test: it does not run in CI and does
  not fail on its own. Turn findings into real tests afterward.

## Safety — the container is not decoration

`TorManager._killOrphanTorForce` (`lib/util/tor_service.dart:497`) runs a bare `pkill -9 tor`
when its targeted pkill misses — the normal case. The container's PID namespace is the only
thing between that and the host's tor. The app's server binds `127.0.0.1:12345`; the network
namespace is the only thing between the injection channel and — or blocked by — the user's
real Prysm. Rules:

- Never run the app outside the container.
- Never unlock the user's real identity. If "Enter Passcode" appears and you did not create
  the lab identity yourself, isolation broke: stop.
- Use a throwaway PIN (`prysmlab onboard --pin 112233`). The lab identity lives in the
  container's writable layer — its keyring is `/home/ubuntu/.local/share/keyrings`, not the
  pub-cache volume — so it dies with the container, and `up --fresh` or any `down` ends it.
- The repo is never written to: `up` stages a copy into `/tmp/prysm-lab/work` and mounts that;
  `tool/live` is mounted read-only.

## Workflow

```sh
prysmlab doctor           # preflight: docker, image, rsync, tor binary; shows host tor/port are irrelevant
prysmlab up               # stage repo, start container, start app; waits for the VM Service line
prysmlab onboard --pin 112233   # reaches home from wherever the app is: first-run wizard,
                                # passcode unlock, or local-data reset, by reading the screen
# observe and act, in a loop:
prysmlab screen           # what is on screen, from the widget tree
prysmlab tap "Settings"   # act
prysmlab down --purge     # teardown is part of the method — always
```

The Android lab is the same seven lines with `-p android`; `doctor` there checks `/dev/kvm`
instead of the repo tor binary, and `up` budgets ~6-7 min from cold (image from the Docker
cache, emulator boot, gradle build). On the narrow Android home the sidebar is behind a
button: `prysmlab -p android tap-widget --type Semantics --contains "Open menu"`.

`up` prints progress; the first run compiles the app (minutes). `up --fresh` destroys
the container first (loses the test identity) and re-stages; `prysmlab sync` re-stages without
relaunching (a running app keeps the old code); `prysmlab restart [--sync]` relaunches the app
in the running container — the way to pick up code changes (hot restart over stdin is not an
option: sending `R` to `flutter run` makes it exit; `--sync` re-stages first). All commands
except the lifecycle ones (`doctor`, `up`, `down`, `sync`, `restart`, `shell`, `build-image`)
are forwarded into the container.

## Rules learned the hard way

1. **`screen` deduplicates texts; assert presence per surface with `count`.**
   `prysmlab screen` lists each unique `Text` string once, so one string on two surfaces looks
   like one — and "it's there" hides "it's missing here". `prysmlab count "<string>"` counts
   raw `Text` occurrences in the tree. Two surfaces → count 2.

2. **`eval` wants ONE LINE and only types visible in the target library.**
   Multi-line snippets fail with a baffling "Can't find '}' to match '{'". `prysmlab eval
   --file snippet.dart` (or `--file -` for stdin) flattens for you. The default evaluation
   library is `package:flutter/src/widgets/binding.dart`, NOT `package:prysm/main.dart` —
   main.dart does not import most widgets, so `Tooltip` "isn't a type" there. To reach an
   app store's own library: `prysmlab libs <substring>` to find it, then `prysmlab eval --lib
   package:prysm/util/group_pending_invite_store.dart '<expr>'`.

3. **Async results cannot be awaited through `evaluate`.**
   The VM service returns synchronously; a Future resolves later. Print inside `.then()` and
   read the result from the app log: `prysmlab logs --grep 'PENDING_COUNT='`.

4. **`localToGlobal` returns coordinates for off-screen widgets; blind taps fail silently.**
   A widget scrolled out of the viewport still reports a center, the pointer event lands on
   nothing, and nothing happens. `prysmlab tap` runs the real hit test first and refuses with
   `OCCLUDED n=… x=… y=…` when the coordinate resolves to something else. `OCCLUDED` means
   scroll it into view or close the route covering it — NOT that the widget is missing
   (`NOTFOUND` is missing). `tap` autoscrolls by default; `--no-scroll` disables that, `--force`
   taps anyway. `prysmlab where "<text>"` reports `hit=yes/no` without sending events;
   `prysmlab scroll <dy>` jumps the longest scrollable when autoscroll is not enough.

5. **`SettingsScreen` is a branch of HomeScreen's build, not a route.**
   `showSettings` (`lib/screens/home/home_screen.dart:135`) selects it as the main pane
   (`:2146`, `if (showSettings) return SettingsScreen(onClose: …)`); there is no route to
   pop, so `prysmlab pop` returns `CANNOT-POP` there — observed. Exit it with its own
   close button.
   `PrivacySettingsScreen` and `InviteRequestsScreen` are real pushed routes —
   `pop` works there. An unexpected `CANNOT-POP` means you are higher in the stack than you
   think.

6. **An open route covers what is under it.**
   A pushed route overlays the previous screen; a tap aimed at the covered screen's
   coordinates lands on the route (or nothing). Close the covering route first, then tap
   through.

7. **Keyboard traversal is useless here.**
   The reason is in the widget: `PrysmPressable` (`lib/ui/core/prysm_pressable.dart:31`) builds
   a bare `GestureDetector` — no `Focus`, no `InkWell`, no focusable ancestor of its own — so
   its buttons are never in the traversal order. The focus tree itself is real and populated
   (on HomeScreen, `prysmlab screen --tree focus` prints 85 lines and `primaryFocus` is a live
   `Focus` node, reached via `Focus <- Semantics <- _FocusInheritedScope <- Focus <-
   CallbackShortcuts <- HomeScreen`); traversal just never reaches the controls. Verify with
   `prysmlab screen --tree focus` before wasting time on it (`--tree` also accepts
   `render|layer|semantics` for the other debugDump trees). Real dialogs (GTK/secret-service
   prompts) need real input — that is what the container's setup avoids.

8. **The identity survives a restart; the runbook's reset-and-re-onboard loop was a bug in
   its launcher.** The runbook claimed every restart lands on StartupFatalErrorScreen ("Local
   data error", `DATABASE_KEY_V1 could not be persisted to secure storage`). Root cause: it
   unlocked the keyring with `printf '' | gnome-keyring-daemon --unlock` — a bare EOF, no
   newline. The daemon then never creates `login.keyring`, so the first `flutter_secure_storage`
   write pops a `gcr-prompter` GUI dialog that blocks the app's main isolate forever — which is
   also the real explanation of the runbook's "debugDumpApp times out" symptom. `labd.sh` uses
   `printf '\n'` — empty password *plus newline* — and the daemon creates `login.keyring` +
   `user.keystore` silently. Verified: `prysmlab restart` took 5.4 s and came back on
   `UnlockScreen` / "Enter Passcode", not on a data error; `prysmlab onboard --pin 112233` then
   reached HomeScreen in 3.8 s by entering the PIN. Treat `onboard` as the single "get me to the
   home screen" command: it handles the first-run wizard, the passcode unlock, and the "Reset
   local data and continue" button, because it reacts to what is on screen instead of replaying
   a fixed script.

9. **`evaluate` needs the WebSocket transport.** The VM Service also answers plain HTTP GET
   JSON-RPC (`curl "$BASE/getVM"` works), which is tempting. Over HTTP every `evaluate` fails
   with `No compilation service available; cannot evaluate from source` — the same sentence the
   runbook attributes to running a prebuilt bundle, but from a different cause: flutter_tools
   registers its compileExpression service on the WebSocket session, so `prysmlab` speaks
   WebSocket. Worth knowing because that error message otherwise sends you hunting for the
   wrong problem.

10. **A missing *system* D-Bus hangs the app before its first frame.** Symptom: the bundle
    builds, a window opens, the VM Service comes up, and `prysmlab screen` returns
    `{"screens": [], "texts": [], "lines": 2}` — the raw dump says `<no tree currently
    mounted>`. Cause: `battery_plus` asks UPower over the system bus
    (`BatterySaverService.init` -> `_refresh` -> `Battery.batteryLevel`); with no
    `/run/dbus/system_bus_socket` the DBus stream throws asynchronously, the future never
    completes, `AppBootstrap.initializeServices` never returns and `runApp` is never called.
    Trap: `BatterySaverService._refresh` wraps the await in a try/catch, and it does not help,
    because the throw arrives on the zone from `DBusSignalStream._onListen`, not from the
    awaited future. `labroot.sh` starts `dbus-daemon --system` and `upowerd`, and `up` runs it.
    It also waits for the bus *name* `org.freedesktop.UPower` and exits non-zero
    (`PRYSMLAB_UPOWER_FAILED`) when nothing claims it — a live `upowerd` process is not proof
    that it owns the name, and proceeding anyway turns this loud cause into a bare timeout.
    Sibling failure: without `xdg-user-dirs` installed, path_provider_linux throws
    `MissingPlatformDirectoryException(Unable to get application documents directory)` and
    bootstrap dies the same way.

11. **The injection channel: `prysmlab peer`, plus `eval` in the crypto library.** The app's
    loopback server is the third channel. `prysmlab peer public` (verified: 200 with the app's
    real `signPublic`/`agreePublic`/`fingerprint` JSON), `prysmlab peer onion` (verified:
    returns the lab's `.onion`, read from
    `~/Documents/prysm/tor_executable/tor_data/hidden_service/hostname`), and
    `prysmlab peer post --json <file|->`, which POSTs to `/message`. What you must get right:
    `POST /message` authenticates nobody, but `_validateAddressedToLocal`
    (`lib/server/inbound_message_router.dart:296`) rejects the request unless `receiverId`
    equals the app's own onion. For envelopes that need real crypto, the durable way is
    `prysmlab eval --file <snippet.dart> --lib package:prysm/crypto/group_crypto.dart`: the
    snippet runs inside the app, so `GroupCryptoV2.encryptControlPayload`,
    `IdentityKeyPair.generate()` and `dart:io`'s HttpClient are all in scope, and there is no
    throwaway `flutter test` file to build, forget to delete, or trip over (`HttpOverrides.global
    = null`, per the runbook). Observe the effect of an injection with `prysmlab wait "<text>"`,
    which polls until the string appears in the tree.

12. **`type` goes through `EditableTextState.updateEditingValue`.**
    `prysmlab type "<text>" [-n IDX] [--submit]` (verified working) finds an `EditableText` and
    feeds the text through `updateEditingValue` — the real platform-input entry point — so input
    formatters run and `onChanged` fires. Assigning to `controller.text` instead fires neither.

13. **`tap` can never open a long-press menu; use `longpress`.**
    `tap` sends down and up in the same turn, far below any
    `LongPressGestureRecognizer` deadline, so the whole class of "hold down and nothing
    happens" defects was invisible to this lab until `longpress` existed.
    `prysmlab longpress "<text>" | --type <Widget> [--contains …] [-n IDX] [--hold MS]`
    holds the pointer and schedules the release on the app's own event loop (`evaluate` is
    synchronous, so it cannot wait). **Read the result with the next `screen`/`count`, not
    from the command's output** — the command returns while the gesture is still in flight.
    Message bubbles carry their text in `RichText`, not `Text`, so target them with
    `--type RichText --contains "<word>"`; a composer is `--type PrysmEditableText`.

14. **A long press does different things per platform, and both are correct.**
    `TextSelectionGestureDetectorBuilder.onSingleLongTapStart` branches on
    `defaultTargetPlatform`: on Android it selects the word under the finger, on Linux/Windows
    it only moves the caret when the field already has focus. So an empty-looking Linux result
    (`sel=105..105`, menu with just "Select all") is not a bug and does not refute an Android
    report. The desktop gesture for the same menu is a **secondary tap**: fire a
    `PointerDownEvent(buttons: kSecondaryButton)` through `eval`. It calls `toggleToolbar()`,
    so if the menu is already open the first right-click closes it.

15. **The emulator's clipboard is dead; assert on `Cut`, not `Copy`.**
    On the headless AVD `Clipboard.setData` followed by `Clipboard.getData` returns `<null>`
    even with no UI involved, and `adb shell cmd clipboard` does not exist on the android-34
    image: Android denies clipboard access to an app without window focus, and `-no-window`
    never has it. A missing "Paste" entry in the selection menu is this, not a defect. What is
    observable in-app is `Cut` — it mutates the field — and the app's own
    "Copied to clipboard" toast.
    The **soft keyboard is a different story, and the earlier version of this rule was wrong**:
    it never shows for *injected* pointers (`tap`, `longpress`, `TextInput.show` from an `eval`)
    — `mInputShown=false` no matter what — because Flutter's own pointer events never make the
    Android view the IME's served view. It shows perfectly for **real touch**:
    `adb shell input tap <x*dpr> <y*dpr>`, read back with
    `adb shell dumpsys input_method | grep mInputShown`. Measured on the headless AVD, debug and
    release builds alike: tap the field -> `mInputShown=true`, BACK -> `false`, tap again ->
    `true`. So the whole class of "the keyboard does not come back" defects IS testable here —
    it just needs `docker exec <container> adb shell input`, coordinates in physical pixels
    (logical × `devicePixelRatio`, 2.75 on the `pixel_5` AVD), and widget geometry read from the
    tree with an `eval` because a screenshot cannot tell you where a 20 dp text strip ends.
    Two traps that cost a session: a BACK sent while the keyboard is already closed pops the
    route and eventually tears the app's tree down (guard every BACK on `mInputShown=true`), and
    the first real tap after an app relaunch or a system permission dialog is swallowed — check
    `adb shell dumpsys window | grep mCurrentFocus` before trusting a negative result.
    To exercise what a keyboard does to *layout* without the keyboard, shrink the display:
    `adb shell wm size 1080x1600` moves every bottom-anchored widget up by ~270 dp and forces
    the same relayout, `adb shell wm size reset` restores it.

16. **A group chat is reachable without a second peer — create it with an `eval`.**
    Adding a contact through the UI needs the peer online (it fetches their public key over
    Tor), so the group screens look untestable. They are not: `GroupService.createGroup` only
    needs a member *string*. Take the live `HomeScreen` widget's `onionAddress` and `keyManager`
    (walk the element tree; the field is `onionAddress`, not `userId`), then
    `GroupService(userId: home.onionAddress, keyManager: home.keyManager).createGroup('name',
    ['<56 base32 chars>.onion'])` from `--lib package:prysm/screens/group_chat.dart`, which is
    where both `GroupService` and the widget types are visible. Print the id from `.then()` and
    read it with `logs --grep` (rule 3). The invite delivery fails against the fake onion and
    that is fine — the group, its key and its membership are already committed locally.
    `restart` once: HomeScreen caches the "N contacts · N groups" counts and will not show the
    group until it re-reads the DB. After that the group chat is a normal screen — compose,
    send, `longpress --type RichText --contains "<word>"` on the bubble.

17. **Two peers, real Tor: the lab can test transmission, not just UI.**
    The Linux lab is a second identity in a second container: every host resource is
    env-overridable, including the pub-cache volume (`VOLUME = os.environ.get("PRYSMLAB_VOLUME", …)`,
    `tool/live/prysmlab:148`), so a second peer is `PRYSMLAB_CONTAINER=prysm-lab-b
    PRYSMLAB_HOST_LAB=/tmp/prysm-lab-b PRYSMLAB_VOLUME=prysm-lab-b-pub tool/live/prysmlab up`. Identity
    lives in the container's writable layer, so each container IS a new identity; the image is shared,
    so build once and `up` both. Peers talk over the real Tor network — no host ports are published and
    there is no LAN/direct transport. Pairing is a real Tor round trip: "Add contact" fetches the peer's
    public key, so the peer must be ONLINE. Measured: Linux→Linux 2.5 s and 7.1 s, Linux→Android 9.6 s,
    Android→Linux 21.8 s (a cold phone Tor sits near the 2×12 s ContactAddService ceiling). A real-member
    group is `GroupService(userId: home.onionAddress, keyManager: home.keyManager).createGroup('name',
    ['<peer onion>'])` from `--lib package:prysm/screens/group_chat.dart`, with `onionAddress`/`keyManager`
    off the live `HomeScreen` widget (rule 16); invite delivery is a sequential fan-out, measured
    0.58-1.22 s per member. `tool/live/txlab` runs the measurement: host clock for the tap, app-log
    timestamps for arrival and ack (UTC — parse with `calendar.timegm`, never `time.mktime`), widget-tree
    poll for render. Baseline, 1:1 Linux↔Linux over an established WS link: median wire 0.43 s, ack
    0.22 s, bubble on screen 1.47 s, 0 lost in 36 messages; serialized outbound ceiling ~1.4 msg/s
    (20-message programmatic burst, median inter-arrival 0.71 s, all in order); a peer that was offline
    drains its backlog 8-11 s after it returns. Re-check, don't re-discover: (1) a stale WS link costs
    the full 30 s `_wsSendBudget` before HTTP fallback — 1 send in 10 to the Android peer took ~50 s,
    zero occurrences Linux↔Linux; (2) a group invite applies to the DB in ~1 s but the receiver's
    conversation list does not refresh — invisible on Android until an app restart, ~15.6 s on Linux;
    (3) two members of the same group who are not mutual contacts cannot form a WS link at all
    (`rejecting hello from unknown peer`; identity resolution is cache-only by design at
    lib/transport/inbound_ws_peer_link.dart:229-237), so their first group message took 134 s and later
    ones still ran 19-22 s against 0.6 s for a contact pair.

18. **Articulated messages and heavy attachments are measurable too — and the numbers decide.**
    `txlab send FROM TO --text-file <path>` sends a multi-paragraph body (the unique mark is its
    FIRST line, because `prysmlab type` echoes the composer on ONE line as `now=…` and a body
    with newlines is only visible up to the first one — verifying against the whole body skips
    every rep). `txlab file FROM TO --size 2MiB [--type image]` covers attachments: the payload is
    written INSIDE the sender's container through the eval channel (a 64 KiB pseudo-random block
    repeated with native `writeFromSync` — generating N bytes closure-by-closure stalls the app
    isolate), then sent through `ChatService.sendFileMessage` with
    `--lib package:prysm/screens/chat.dart`, because the UI path needs the native picker and, for
    images, a modal preview no harness can tap. `--lib` is STICKY: reset it with
    `eval --lib package:flutter/src/widgets/binding.dart 1` or every later `tap`/`type` in that
    container dies with a Dart compile error.
    Both commands report, per message, `send=` (sender's transport completion), `recv=` (receiver's
    arrival line) and `render=` (bubble in the receiver's tree), all against the host clock taken
    just before the send. Two things that look like bugs and are not: `send` LARGER than `recv` by
    ~0.3 s on the WS path is the ack being logged after delivery, and the sender's `send ok` can
    land after the receiver's bubble — read it with a bounded poll, not a single read, or the rep
    reports no send side at all.
    Baseline A, before the 8-chunk window (#152), 1:1 Linux↔Linux, warm WS link: 997-char body recv
    **0.68 s** / render 0.80 s; 200 KiB attachment recv 2.1-3.4 s; 2 MiB monolithic 13.4 s
    (1255 kbps) versus **23.0 s** (729 kbps) chunked; 8 MiB monolithic 45.9 s (1462 kbps) versus
    **112.0 s** (599 kbps) chunked, 33 chunks. Contact add 5.5 s each way. 0 lost in 16 messages.
    Baseline B, 2026-08-14, same rig WITH the window merged, chunked-vs-mono measured in one
    session by returning `false` from `shouldUseChunkedTransfer` in the staged copy for the mono
    half: short text recv median **0.75 s** / render 1.09 s (n=6); 975-char body recv 0.63 s
    (n=3 each way); group text recv median **0.58 s** (n=4); 200 KiB mono recv 1.8-2.7 s;
    2 MiB **chunked 9.4 s** (1778 kbps, n=3) versus **mono 10.7 s** (1570 kbps, n=3) — parity;
    8 MiB chunked 53.5 s and 122.4 s versus mono 39.2 s and 50.8 s. Pairing 5.7-7.9 s. 0 lost in
    31 messages / 32 MiB.
    So the window closed most of the gap the older numbers show — 2.4× faster at 2 MiB, 2.1× at
    8 MiB — and chunked is no longer the obviously wrong choice: it ties one POST at 2 MiB and
    still loses at 8 MiB. Tor variance dominates single reps (the same 8 MiB chunked transfer ran
    53 s and 122 s an hour apart), so never conclude from n=1, and re-measure both halves in ONE
    session before touching either path.
    Group attachments are NOT in the harness: `txlab file` drives `ChatService.sendFileMessage` on
    a live `ChatScreen`, and a `GroupChatScreen` gives `NOTFOUND ChatScreen`. Driving
    `GroupChatService.sendFileMessage` by hand shows the group path never chunks (`path=mono`,
    2 MiB in 10.2 s and 25.2 s) — it fans one monolithic POST out per member.
    Do not "optimise" an attachment path on either number alone, and do not trust a code reading
    over a measurement — the campaign that produced these numbers is also what found that chunked
    transfers had been failing outright since 2026-08-04 (`FormatException: Invalid file
    envelope`), which no test caught because the test hand-built the envelope the parser expected
    instead of the one `CryptoWire.encryptFile` produces.

19. **After the receiver restarts, the first send costs 20-50× the warm one — and `path=chunked`
    can be a lie.** Measured 1:1 Linux↔Linux, sending to a peer that had just restarted: first
    text **18.2 / 20.9 / 39.1 / 51.1 s** (n=4) against 0.75 s warm; first 200 KiB 11.4 s against
    1.8-2.7 s. The sender first burns two 8 s `wsIfConnected` timeouts on the dead link, then
    rebuilds the circuit. Worse, once: the sender logged `WS ready peer=…` and opened a chunked
    transfer while the receiver's log shows NO `handshake complete` until 3.5 minutes later — the
    begin ack could not arrive, the transfer died on its 30 s timeout, and HTTP delivered the
    2 MiB at **220 s**. `txlab` used to print `path=chunked` for that rep because it keyed off the
    `begin transfer=` line alone; it now prints **`chunked->http`** when the sender logs
    `falling back to HTTP send` after the begin (verified by patching `ackTimeout` to 1 ms in the
    staged copy and reproducing the label). Read that label before believing any attachment number.
    Two lab hazards from the same campaign: `prysmlab restart --sync` twice left peer `a` wedged on
    `UnlockScreen` with `Zone error: Build scheduled during frame` — every PIN tap ignored, and a
    plain `prysmlab restart` recovered it; and once, over ~18 minutes, a receiver's open chat pane
    showed nothing newer than the moment it opened while 7 messages arrived, all of them stored
    with `status=received` and returned by the pane's own `getMessagesBetweenBatchWithId` query
    (an app restart made them appear). NOT reproduced in three deliberate attempts afterwards, so
    treat it as an open sighting, not a known bug — and check the tree, not the log, before
    trusting a render number.

## Worked example

Reach home, open the self-chat, and prove "Chat with myself" is on two surfaces (sidebar
tile + main-pane header — both are `Text` widgets, and the sidebar stays visible because
only the main pane swaps):

```sh
prysmlab doctor
prysmlab up --timeout 900
prysmlab onboard --pin 112233
prysmlab tap "Chat with myself"
prysmlab count "Chat with myself"     # -> "   2  Chat with myself"
prysmlab screen                        # 'texts' lists it ONCE (deduplicated)
```

`count` returning 2 is the assertion: the string is present on both surfaces. A single
`screen` entry would have looked like "present" while a surface was missing. (The sidebar
"Chat with myself" tile is always there; the header appears once the self-chat is open.)

## Cleanup — part of the method

```sh
prysmlab down --purge
```

Removes the container, the pub-cache volume, the staging dir and the image, then prints a
verification block: leftover container/volume/staging/image, host tor processes, and the
repo working tree (`git status --porcelain`). Nothing from the session may remain; the repo
was never written to, so the working tree should be clean. If the container is still needed,
`prysmlab down` alone keeps the volume and image.

Measured on this machine, with the image already built: `up --fresh` to a rendered
`OnboardingScreen` 90 s (native bundle compile included), `onboard` to HomeScreen 22 s,
`restart` back to `UnlockScreen` 5.4 s, `down --purge` 2 s. The runbook this supersedes
budgeted 20-30 minutes; almost all of that was the keyring dialog and the re-onboarding
loop it forced. Building the image from scratch is the one slow step (minutes), and `up`
does it automatically when the image is missing.

Use this when the defect lives in UI<->state integration — exactly where widget tests hang
(screens that read the DB in `initState` deadlock under fake-async) and where
`evaluate`-driven observation shines.
