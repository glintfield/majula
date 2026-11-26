#!/bin/sh
# Runs the Swift client tests on macOS and the iOS simulator against a fresh spike server.
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SPIKE="$ROOT/spike"
APPLE="$SPIKE/apple"
PORT=${SPIKE_PORT:-18443}
SIM=${SPIKE_SIM:-iPhone 17}
DERIVED="$APPLE/.build"
# xcode-select often points at the Command Line Tools, which have no XCTest or simulators
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

for tool in node openssl curl xcodebuild xcrun; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
if [ ! -d "$SPIKE/node_modules/tsx" ]; then
  echo "run: npm --prefix spike install" >&2
  exit 1
fi
case $(node --version) in v22.*) ;; *) echo "warning: spike targets Node 22, found $(node --version)" >&2 ;; esac

WORK=$(mktemp -d)
PID=
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

sh "$SPIKE/scripts/init-ca.sh" "$WORK/ca" >/dev/null
sh "$SPIKE/scripts/init-ca.sh" "$WORK/wrong" >/dev/null
fingerprint() {
  openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f'
}
INITIAL_LEAF=$(fingerprint "$WORK/ca/leaf.crt")

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

der_b64() {
  openssl x509 -in "$1" -outform der | base64 | tr -d '\n'
}
export TEST_RUNNER_SPIKE_URL="https://localhost:$PORT"
export TEST_RUNNER_SPIKE_TOKEN=spike-test-token
export TEST_RUNNER_SPIKE_CA_DER_B64="$(der_b64 "$WORK/ca/ca.crt")"
export TEST_RUNNER_SPIKE_WRONG_CA_DER_B64="$(der_b64 "$WORK/wrong/ca.crt")"
export TEST_RUNNER_SPIKE_INITIAL_LEAF_SHA256="$INITIAL_LEAF"
export TEST_RUNNER_SPIKE_WATCH_INTERVAL_MS=100

xcrun simctl boot "$SIM" 2>/dev/null || true

echo "== SpikeClient on macOS"
(cd "$APPLE/SpikeClient" && xcodebuild test -scheme SpikeClient -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" -quiet)

echo "== SpikeClient on $SIM"
(cd "$APPLE/SpikeClient" && xcodebuild test -scheme SpikeClient \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DERIVED" -quiet)

echo "== SpikeHost backgrounding on $SIM"
xcodebuild test -project "$APPLE/SpikeHost/SpikeHost.xcodeproj" -scheme SpikeHost \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DERIVED" -quiet

echo "all Swift client tests passed"
