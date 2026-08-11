#!/bin/sh
# prysmlab — in-container launcher for the real Prysm Android app on an emulator.
# Started by `prysmlab up` as: sh -lc '/opt/lab/android/labd.sh > ~/lab/app.log 2>&1'
#
# The Android sibling of tool/live/labd.sh: create the AVD, boot the emulator
# headless, PROVE it booted (a running qemu process is not a booted device —
# same lesson as PRYSMLAB_UPOWER_FAILED on Linux), forward the app's loopback
# port, regenerate android/local.properties (the host's copy points at host
# paths), then `flutter run`. Every failure mode emits an explicit token that
# `prysmlab up` recognises and reports with the actual cause.
set -e

LAB="$HOME/lab"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
AVD="prysmlab"
EMU="$ANDROID_HOME/emulator/emulator"
mkdir -p "$LAB" "$HOME/.android/avd" /tmp/android-unknown
export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"

# KVM is a hard requirement for the x86_64 system image: without it the emulator
# refuses to start. `prysmlab up` passes --device /dev/kvm on docker run; confirm
# it here with an explicit failure token instead of a bare emulator error later.
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "PRYSMLAB_KVM_FAILED: /dev/kvm is not usable inside the container" >&2
  exit 1
fi

# Create or refresh the AVD. `echo no` answers the "custom hardware profile"
# prompt; --force keeps repeated container starts idempotent.
#
# -d pixel_5 is not cosmetic: without a device profile avdmanager falls back to
# a 320x640 screen, which is smaller than any shipping phone. Layout defects
# that only a real phone shows (and layout *reports* from users) cannot be
# reproduced or refuted on a screen no user has. pixel_5 is 1080x2340 @440dpi,
# i.e. 393x851 logical pixels — an ordinary modern phone.
if ! "$EMU" -list-avds | grep -qx "$AVD"; then
  echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
    --force -n "$AVD" -d pixel_5 -k "system-images;android-34;default;x86_64" \
    >"$LAB/avd.log" 2>&1
fi

# Headless boot. -no-snapshot keeps every boot honest instead of restoring a
# possibly half-booted snapshot; -accel on makes a missing KVM fail loudly.
# If an emulator for this AVD is already running (e.g. after `prysmlab restart`,
# which re-runs this launcher), reuse it instead of starting a second one.
EMU_PID=""
if ! pgrep -f "qemu-system.*-avd $AVD" >/dev/null 2>&1; then
  "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -accel on >"$LAB/emulator.log" 2>&1 &
  EMU_PID=$!
fi

adb start-server >/dev/null 2>&1 || true

# 1) the device must appear in `adb devices` as "device" ...
i=0
while [ $i -lt 300 ]; do
  if adb devices 2>/dev/null | sed -n 's/^emulator-[0-9]*[[:space:]]*device$/device/p' \
       | grep -q device; then
    break
  fi
  if [ -n "$EMU_PID" ] && ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "PRYSMLAB_EMULATOR_FAILED: emulator exited before adb saw the device" >&2
    tail -40 "$LAB/emulator.log" >&2
    exit 1
  fi
  i=$((i + 1)); sleep 1
done

# ... and 2) Android must finish booting. sys.boot_completed=1 is the contract;
# an online adb device is not proof the system is up.
i=0
while [ $i -lt 300 ]; do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    break
  fi
  if [ -n "$EMU_PID" ] && ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "PRYSMLAB_EMULATOR_FAILED: emulator died during boot" >&2
    tail -40 "$LAB/emulator.log" >&2
    exit 1
  fi
  i=$((i + 1)); sleep 2
done
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
  echo "PRYSMLAB_BOOT_TIMEOUT: sys.boot_completed never reached 1" >&2
  tail -40 "$LAB/emulator.log" >&2
  exit 1
fi
echo "PRYSMLAB_EMULATOR_UP"

# The app's loopback server binds 127.0.0.1:12345 inside the emulator; forward it
# so `prysmlab peer` keeps talking to 127.0.0.1:12345 unchanged.
adb forward tcp:12345 tcp:12345 >/dev/null
echo "PRYSMLAB_ADB_FORWARD_UP"

# android/local.properties must not come from the host (it points at the host's
# SDK paths); regenerate it for the in-container toolchain.
printf 'sdk.dir=%s\nflutter.sdk=/opt/flutter\n' "$ANDROID_HOME" \
  > /work/android/local.properties

cd /work
[ -f .dart_tool/package_config.json ] || flutter pub get

# Deterministic device id: the first emulator in a fresh container is
# emulator-5554; resolve it from adb rather than assuming.
DEVICE=$(adb devices 2>/dev/null | awk '/emulator-[0-9]+[ \t]+device/{print $1; exit}')
if [ -z "$DEVICE" ]; then
  echo "PRYSMLAB_EMULATOR_FAILED: no emulator device in adb" >&2
  exit 1
fi

# flutter run treats stdin EOF as quit, so it needs a stdin that never ends.
# A FIFO opened read-write is exactly that (same reasoning as the Linux lab).
FIFO="$HOME/lab/app-stdin"
rm -f "$FIFO"
mkfifo "$FIFO"
flutter run -d "$DEVICE" --debug --no-pub --disable-service-auth-codes <> "$FIFO"
rc=$?
rm -f "$FIFO"
exit "$rc"
