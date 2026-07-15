#!/usr/bin/env bash
# Device e2e (roadmap M5): build + install the host app on a connected
# physical iPhone, launch it against the Mac's LAN PE with token auth, and
# assert the PE received the three canonical families.  Background-delivery
# validation is interactive — the script prints the checklist at the end.
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 [PE_BASE_URL=http://<lan-ip>:3004] \
#     [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_device.sh
#
# Requires: Xcode, xcodegen, jq, a connected + paired iPhone (Developer
# Mode enabled), and an Apple Developer team for code signing.
set -euo pipefail

BUNDLE_ID="org.energyos.HealthKitBridgeApp"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The phone must reach the PE over the LAN — never localhost.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
PE_BASE_URL="${PE_BASE_URL:-http://${LAN_IP}:3004}"
case "$PE_BASE_URL" in
  *127.0.0.1*|*localhost*)
    echo "PE_BASE_URL is loopback ($PE_BASE_URL) — the phone cannot reach it. Use the Mac's LAN IP." >&2
    exit 1 ;;
esac

[ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "DEVELOPMENT_TEAM is required for device code signing." >&2; exit 1; }

echo "── Device discovery"
DEVICE_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICE_JSON" > /dev/null
DEVICE_ID="$(jq -r '[.result.devices[] | select(.hardwareProperties.deviceType == "iPhone" and .connectionProperties.tunnelState != "unavailable")][0].identifier // empty' "$DEVICE_JSON")"
DEVICE_NAME="$(jq -r '[.result.devices[] | select(.hardwareProperties.deviceType == "iPhone" and .connectionProperties.tunnelState != "unavailable")][0].deviceProperties.name // empty' "$DEVICE_JSON")"
rm -f "$DEVICE_JSON"
[ -n "$DEVICE_ID" ] || { echo "No connected iPhone found (xcrun devicectl list devices). Pair the device and enable Developer Mode."; exit 1; }
echo "   $DEVICE_NAME ($DEVICE_ID)"

echo "── PE preflight (from Mac): $PE_BASE_URL"
curl -sf "$PE_BASE_URL/api/integrations/healthkit/status" | jq -e '.ingestEndpoint == "/api/integrations/healthkit/ingest"' > /dev/null

before="$(curl -sf "$PE_BASE_URL/api/sources" \
  | jq -c '[.sources[] | select(.origin == "healthkit")] | sort_by(.sensorId)')"

echo "── Generate + build (team $DEVELOPMENT_TEAM)"
cd "$REPO_ROOT/App"
xcodegen generate --quiet
xcodebuild -project HealthKitBridgeApp.xcodeproj -scheme HealthKitBridgeApp \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build -quiet \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  build

APP_PATH="$(find build/Build/Products -name HealthKitBridgeApp.app -path '*iphoneos*' | head -1)"
[ -n "$APP_PATH" ] || { echo "device app bundle not found"; exit 1; }

echo "── Install + launch on $DEVICE_NAME (PE=$PE_BASE_URL)"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" \
  -autoTestPush 1 \
  -peBaseURL "$PE_BASE_URL" \
  ${HEALTHKIT_BRIDGE_TOKEN:+-bridgeToken "$HEALTHKIT_BRIDGE_TOKEN"}

echo "── Waiting for sensors to land"
found=0
for i in $(seq 1 20); do
  sleep 2
  found=$(curl -sf "$PE_BASE_URL/api/sources" | jq '[.sources[] | select(.origin == "healthkit")] | length' 2>/dev/null || echo 0)
  after="$(curl -sf "$PE_BASE_URL/api/sources" \
    | jq -c '[.sources[] | select(.origin == "healthkit")] | sort_by(.sensorId)' 2>/dev/null || echo '[]')"
  [ "$found" -ge 3 ] && [ "$after" != "$before" ] && break
done
[ "$found" -ge 3 ] || { echo "FAIL: expected ≥3 healthkit sensors, saw $found"; exit 1; }
[ "$after" != "$before" ] && changed="updated by this run" || changed="WARNING: unchanged since before the run"

curl -sf "$PE_BASE_URL/api/sources" \
  | jq -r '.sources[] | select(.origin == "healthkit") | "  \(.sensorId) @ [\(.region.offset):\(.region.offset + .region.length)] = \(.lastValue)"'
echo "PASS: $found healthkit sensors live on the PE ($changed)"

cat <<'CHECKLIST'

── Background-delivery validation (manual, roadmap M5) ─────────────────
 1. In the app: authorize HealthKit, start observers (watchdog arms,
    default 30 min; tune with -silenceThresholdMinutes).
 2. Background the app (swipe home). Record a BP reading / workout /
    sleep sample (Apple Watch or Health app manual entry).
 3. Expect a new batch on the PE within ~1–2 min (immediate background
    delivery): curl <PE>/api/sources | jq '[.sources[] |
    select(.origin=="healthkit")]'
 4. Force-kill the app, add another sample — HealthKit relaunches the
    app in the background; verify another PE update.
 5. TTL re-arm: PE sensors expire after ttlMs (900 s default). After
    expiry, the next Health sample must re-create the sensor.
 6. Silent failure: stop the PE (or break the token), add a sample, and
    confirm the app logs the yellow "No successful delivery in N min"
    alert after the threshold.
────────────────────────────────────────────────────────────────────────
CHECKLIST
