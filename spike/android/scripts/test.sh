#!/bin/sh
# Runs the Kotlin client's instrumented tests on an Android emulator against a fresh spike server.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SPIKE="$ROOT/spike"
ANDROID="$SPIKE/android"
PORT=${SPIKE_PORT:-18443}
AVD=${SPIKE_AVD:-magetd_test}
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

for tool in node openssl curl java adb emulator; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
if [ ! -d "$SPIKE/node_modules/tsx" ]; then
  echo "run: npm --prefix spike install" >&2
  exit 1
fi
case $(node --version) in v22.*) ;; *) echo "warning: spike targets Node 22, found $(node --version)" >&2 ;; esac

WORK=$(mktemp -d)
PID=
EMULATOR_PID=
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  if [ -n "$EMULATOR_PID" ]; then
    adb emu kill >/dev/null 2>&1 || kill "$EMULATOR_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

sh "$SPIKE/scripts/init-ca.sh" "$WORK/ca" >/dev/null
sh "$SPIKE/scripts/init-ca.sh" "$WORK/wrong" >/dev/null
fingerprint() {
  openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f'
}
INITIAL_LEAF=$(fingerprint "$WORK/ca/leaf.crt")

# bound to loopback: the emulator reaches the host's 127.0.0.1 as 10.0.2.2
(cd "$SPIKE" && CERT_DIR="$WORK/ca" SPIKE_PORT="$PORT" SPIKE_TOKEN=spike-test-token \
  SPIKE_WATCH_INTERVAL_MS=100 exec node --import tsx server/main.ts) >"$WORK/server.log" 2>&1 &
PID=$!

i=0
until curl -s -o /dev/null --cacert "$WORK/ca/ca.crt" "https://localhost:$PORT/"; do
  i=$((i + 1))
  if [ "$i" -ge 30 ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "server did not start:" >&2
    cat "$WORK/server.log" >&2
    exit 1
  fi
  sleep 0.5
done

# every client run below must see a leaf issued after the server started
sh "$SPIKE/scripts/rotate-leaf.sh" "$WORK/ca" >/dev/null
kill -HUP "$PID"
i=0
until grep -q 'reloaded leaf certificate' "$WORK/server.log"; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { echo "server did not reload the leaf" >&2; exit 1; }
  sleep 0.25
done

if ! adb devices | grep -q 'emulator-.*device$'; then
  echo "== booting $AVD"
  emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot-save >"$WORK/emulator.log" 2>&1 &
  EMULATOR_PID=$!
  i=0
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    i=$((i + 1))
    if [ "$i" -ge 180 ] || ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
      echo "emulator did not boot:" >&2
      cat "$WORK/emulator.log" >&2
      exit 1
    fi
    sleep 1
  done
fi

der_b64() {
  openssl x509 -in "$1" -outform der | base64 | tr -d '\n'
}
arg() {
  printf -- '-Pandroid.testInstrumentationRunnerArguments.%s=%s' "$1" "$2"
}

echo "== connectedAndroidTest"
(cd "$ANDROID" && ./gradlew --console=plain connectedAndroidTest \
  "$(arg spikeUrl "https://10.0.2.2:$PORT")" \
  "$(arg spikeToken spike-test-token)" \
  "$(arg spikeCaDerB64 "$(der_b64 "$WORK/ca/ca.crt")")" \
  "$(arg spikeWrongCaDerB64 "$(der_b64 "$WORK/wrong/ca.crt")")" \
  "$(arg spikeInitialLeafSha256 "$INITIAL_LEAF")" \
  "$(arg spikeWatchIntervalMs 100)")

echo "all Kotlin client tests passed"
