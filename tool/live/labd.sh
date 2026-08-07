#!/bin/sh
# prysmlab — in-container launcher for the real Prysm desktop app.
# Started by `prysmlab up` as: sh -lc '/opt/lab/labd.sh > ~/lab/app.log 2>&1'
set -e

LAB="$HOME/lab"
DISP="${DISPLAY:-:99}"
mkdir -p "$LAB" "$HOME/Documents/prysm/tor_executable" \
         "$HOME/.local/share/keyrings" "$HOME/.config" "$HOME/.cache" \
         "${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
chmod 700 "${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"

# path_provider_linux resolves getApplicationDocumentsDirectory through
# ~/.config/user-dirs.dirs; without it the app lands somewhere else and the
# pre-seeded tor binary below is ignored.
[ -f "$HOME/.config/user-dirs.dirs" ] || \
  printf 'XDG_DOCUMENTS_DIR="$HOME/Documents"\n' > "$HOME/.config/user-dirs.dirs"

# TorDownloader fetches ~14 MB into <documents>/prysm/tor_executable on first run.
# The repo ships the same binary, so reuse it.
if [ ! -x "$HOME/Documents/prysm/tor_executable/tor" ] && [ -f /work/tor_executable/tor ]; then
  cp /work/tor_executable/tor "$HOME/Documents/prysm/tor_executable/tor"
  chmod +x "$HOME/Documents/prysm/tor_executable/tor"
fi

# The default collection must be the login keyring, which is the one the daemon
# unlocks below; otherwise the first secret write asks to create "Default".
[ -f "$HOME/.local/share/keyrings/default" ] || \
  printf 'login' > "$HOME/.local/share/keyrings/default"

if ! xdpyinfo -display "$DISP" >/dev/null 2>&1; then
  Xvfb "$DISP" -screen 0 1440x900x24 -nolisten tcp >"$LAB/xvfb.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    xdpyinfo -display "$DISP" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
xdpyinfo -display "$DISP" >/dev/null 2>&1 || { echo "PRYSMLAB_XVFB_FAILED"; exit 1; }
echo "PRYSMLAB_XVFB_UP $DISP"

cd /work
flutter config --enable-linux-desktop >/dev/null 2>&1 || true
[ -f .dart_tool/package_config.json ] || flutter pub get

exec dbus-run-session -- sh -c '
  # An empty password *followed by a newline*. With a bare EOF (printf "") the
  # daemon never creates login.keyring, and the first flutter_secure_storage
  # write pops a gcr prompt that blocks the app main isolate forever — which
  # looks exactly like a hung debugDumpApp.
  eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
  export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
  secret-tool store --label=prysmlab-probe prysmlab probe </dev/null 2>/dev/null \
    && echo "PRYSMLAB_KEYRING_UP" || echo "PRYSMLAB_KEYRING_DEGRADED"
  cd /work
  # flutter run treats stdin EOF as quit, so hold stdin open with a writer that
  # never writes.
  sleep 2147483647 | flutter run -d linux --debug --no-pub --disable-service-auth-codes
'
