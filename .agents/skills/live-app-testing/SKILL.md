---
name: live-app-testing
description: "Use when you need to prove UI<->state integration on the real, running Prysm desktop app: screens render what the stores contain, taps land, routes open and close. Proves the app's own wiring end to end. It does NOT prove pixels, does NOT prove the compositor's input path, and does NOT run in CI."
---

# Live App Testing

Drive the real Prysm Linux desktop app with `tool/live/prysmlab` — observation (Dart VM
Service widget trees), control (in-app pointer events via `evaluate`), and data injection
(HTTP against the app's loopback server). The app runs in a throwaway container under Xvfb
with a private D-Bus session and keyring.

## When to use it — and when not

Use it when the defect lives in the integration between UI and state: a screen that does not
show what the DB holds, a tap that does not reach its handler, a route that does not open or
close, a store whose change the UI never reflects. That is where this method found real bugs.

Do NOT use it for:

- **Pixels.** The dump is text: what is in the tree, not how it looks. Alignment, contrast,
  truncation, overlap are invisible here. `prysmlab shot` writes a PNG of the Xvfb framebuffer
  (verified: 1440x900), but producing an image is not reading one: with no vision-capable tool
  available, the PNG proves nothing on its own.
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

`up` prints progress; the first run compiles the Linux bundle (minutes). `up --fresh` destroys
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
