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
  http://*|https://*) ;;
  *) PE_BASE_URL="http://$PE_BASE_URL" ;;
esac
PE_BASE_URL="${PE_BASE_URL%%\?*}"
PE_BASE_URL="${PE_BASE_URL%%#*}"
case "$PE_BASE_URL" in
  */api|*/api/*) PE_BASE_URL="${PE_BASE_URL%%/api*}" ;;
esac
PE_BASE_URL="${PE_BASE_URL%/}"
case "$PE_BASE_URL" in
  *127.0.0.1*|*localhost*)
    echo "PE_BASE_URL is loopback ($PE_BASE_URL) — the phone cannot reach it. Use the Mac's LAN IP." >&2
    exit 1 ;;
esac

# Lane TLS (localHealthkitBridge#52). An https PE serves the device routes
# (healthkit ingest, /status, /scope) on TLS 1.3 without a client certificate,
# as the phone calls them, and answers every other route 403 without a lane
# client certificate (RealityEngine_CI docs/TRANSPORT_SECURITY.md). So the
# preflight reads /status the way the phone does, and the checks on
# /api/sources and /api/integrations/status present the harness's certificate:
# RE_HARNESS_TLS_* (exported by the RealityEngine_CI harness when the lane is
# on), else the lane PKI's own files.
pe_device() { curl -sf "$@"; }
pe_service() { curl -sf "$@"; }
case "$PE_BASE_URL" in
  https://*)
    pki="${RE_PKI_DIR:-$HOME/.reality-engine/pki/${RE_PKI_LANE:-native}}"
    TLS_CA="${RE_HARNESS_TLS_CA:-$pki/ca/ca.crt}"
    TLS_CERT="${RE_HARNESS_TLS_CERT:-$pki/issued/harness/chain.pem}"
    TLS_KEY="${RE_HARNESS_TLS_KEY:-$pki/issued/harness/key.pem}"
    for f in "$TLS_CA" "$TLS_CERT" "$TLS_KEY"; do
      [ -r "$f" ] || { echo "https PE, but $f is not readable: set RE_HARNESS_TLS_CA/CERT/KEY or RE_PKI_DIR." >&2; exit 1; }
    done
    # macOS's /usr/bin/curl (LibreSSL) cannot complete a handshake under the
    # profile; use a curl built on OpenSSL or another TLS 1.3 library, as
    # RealityEngine_CI's lane_curl does.
    TLS_CURL=""
    for c in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl "$(command -v curl 2>/dev/null || true)"; do
      [ -n "$c" ] && [ -x "$c" ] || continue
      if "$c" -V 2>/dev/null | head -1 | grep -q -E "OpenSSL|BoringSSL|GnuTLS|wolfSSL|rustls"; then TLS_CURL="$c"; break; fi
    done
    [ -n "$TLS_CURL" ] || { echo "https PE, but no TLS 1.3-capable curl: install Homebrew curl (brew install curl)." >&2; exit 1; }
    pe_device() { "$TLS_CURL" -sf --tlsv1.3 --tls-max 1.3 --cacert "$TLS_CA" "$@"; }
    pe_service() { "$TLS_CURL" -sf --tlsv1.3 --tls-max 1.3 --cacert "$TLS_CA" --cert "$TLS_CERT" --key "$TLS_KEY" "$@"; }
    echo "── Lane TLS: the phone must trust $TLS_CA (scripts/ca_profile.sh, then full trust in Certificate Trust Settings)"
    ;;
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
pe_device "$PE_BASE_URL/api/integrations/healthkit/status" | jq -e '.ingestEndpoint == "/api/integrations/healthkit/ingest"' > /dev/null
registry_status="$(pe_service "$PE_BASE_URL/api/integrations/status" 2>/dev/null || true)"
if [ -z "$registry_status" ] || ! jq -e '
  ([.sourceMappings[]?.id] | (
    index("healthkit:HKCorrelationTypeIdentifierBloodPressure") != null and
    index("healthkit:HKWorkoutTypeIdentifierWorkout") != null and
    index("healthkit:HKCategoryTypeIdentifierSleepAnalysis") != null
  ))
' > /dev/null <<<"$registry_status"; then
  cat >&2 <<EOF
PE is reachable, but it does not advertise the three canonical HealthKit bridge
family mappings required by this M5 test:
  - healthkit:HKCorrelationTypeIdentifierBloodPressure
  - healthkit:HKWorkoutTypeIdentifierWorkout
  - healthkit:HKCategoryTypeIdentifierSleepAnalysis

Start the PE with the HealthKit-Spezi registry, for example:
  INTEGRATIONS_CONFIG=/path/to/RealityEngine_CPP/config/integrations.healthkit-spezi.example.json npm start
EOF
  exit 1
fi

before="$(pe_service "$PE_BASE_URL/api/sources" \
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
ENV_JSON="$(jq -n \
  --arg peBaseUrl "$PE_BASE_URL" \
  --arg bridgeToken "${HEALTHKIT_BRIDGE_TOKEN:-}" \
  '{AUTO_TEST_PUSH:"1", PE_BASE_URL:$peBaseUrl} + (if $bridgeToken == "" then {} else {HEALTHKIT_BRIDGE_TOKEN:$bridgeToken, BRIDGE_TOKEN:$bridgeToken} end)')"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" \
  --environment-variables "$ENV_JSON" \
  "$BUNDLE_ID" \
  -- \
  -autoTestPush 1 \
  -peBaseURL "$PE_BASE_URL"

echo "── Waiting for sensors to land"
found=0
for i in $(seq 1 20); do
  sleep 2
  found=$(pe_service "$PE_BASE_URL/api/sources" | jq '[.sources[] | select(.origin == "healthkit")] | length' 2>/dev/null || echo 0)
  after="$(pe_service "$PE_BASE_URL/api/sources" \
    | jq -c '[.sources[] | select(.origin == "healthkit")] | sort_by(.sensorId)' 2>/dev/null || echo '[]')"
  [ "$found" -ge 3 ] && [ "$after" != "$before" ] && break
done
[ "$found" -ge 3 ] || { echo "FAIL: expected ≥3 healthkit sensors, saw $found"; exit 1; }
[ "$after" != "$before" ] && changed="updated by this run" || changed="WARNING: unchanged since before the run"

pe_service "$PE_BASE_URL/api/sources" \
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
