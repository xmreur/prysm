#!/bin/sh
# prysmlab — root-side, once per container: the system D-Bus and UPower.
# Run by `prysmlab up` as `docker exec -u 0 <container> /opt/lab/labroot.sh`.
#
# Why this exists: battery_plus asks UPower for the battery level through the
# *system* bus. With no /run/dbus/system_bus_socket the DBus stream throws
# asynchronously, `Battery.batteryLevel` never completes, so
# AppBootstrap.initializeServices never returns and runApp is never reached — the
# app builds, opens a window and renders nothing, and `debugDumpApp` answers
# "<no tree currently mounted>". A private session bus (dbus-run-session, in
# labd.sh) is not enough; this is a different bus.
set -e

mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork
  i=0
  while [ ! -S /run/dbus/system_bus_socket ] && [ $i -lt 20 ]; do
    i=$((i + 1)); sleep 0.25
  done
fi
[ -S /run/dbus/system_bus_socket ] || { echo "PRYSMLAB_SYSTEM_BUS_FAILED"; exit 1; }

# D-Bus activation of UPower needs the setuid launch helper, which is not
# reliable in a container, so start the daemon outright.
if ! pgrep -x upowerd >/dev/null 2>&1; then
  setsid /usr/libexec/upowerd >/var/log/upowerd.log 2>&1 &
fi

# Wait for the bus NAME, not for the process, and wait unconditionally.
#
# A pgrep hit only proves some upowerd exists — not that it owns
# org.freedesktop.UPower — so the wait used to be skipped exactly when a stale
# daemon was the problem. And the loop had no verdict after it: on failure the
# script still printed PRYSMLAB_SYSTEM_BUS_UP, `prysmlab up` started the app,
# and the only symptom was a later timeout. That is the mute failure this file
# exists to prevent: without UPower, battery_plus never completes,
# AppBootstrap.initializeServices never returns and runApp is never reached.
up=0
i=0
while [ $i -lt 40 ]; do
  if dbus-send --system --dest=org.freedesktop.DBus --print-reply \
       /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null \
       | grep -q org.freedesktop.UPower; then
    up=1
    break
  fi
  i=$((i + 1)); sleep 0.25
done
[ "$up" = 1 ] || { echo "PRYSMLAB_UPOWER_FAILED"; exit 1; }

echo "PRYSMLAB_SYSTEM_BUS_UP"
