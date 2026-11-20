#!/usr/bin/env bash
# Device e2e (roadmap M5): build + install the host app on a connected
# physical iPhone, launch it against the Mac's LAN PE with token auth, and
# assert the PE received the three canonical families.  Background-delivery
# validation is interactive — the script prints the checklist at the end.
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 [PE_BASE_URL=http://<lan-ip>:3004] \
#     [HEALTHKIT_BRIDGE_TOKEN=...] [PIM_BASE_URL=https://<lan-ip>:<port>] \
#     ./scripts/e2e_device.sh
#
# With PIM_BASE_URL the launch also points the app at that PIM (the
# healthkit-to-pim link, #52): the app reads PIM's /healthz and its resident
# records on launch, and the run passes only if the app reports it linked and
# synchronized. The app prints flags only; its console is captured for them.
# PIM_BASE_URL is PIM's device listener (PIM#91), which requires the bridge
# token on hydration: PIM_TOKEN, default HEALTHKIT_BRIDGE_TOKEN, reaches the
# app as an environment variable, never as an argument.
#
# With PIM_OWNER_URL as well (PIM's loopback API, reached from this Mac) the
# run also mirrors from the phone (#58, RealityEngine_CI#808): acting as the
# owner, the script declares and approves two test metrics on that API; the
# app (a Debug build) stages a synthetic batch, never the owner's Health data,
# previews it and applies it with -autoApproveMirrorBatch, the unattended
# approval Release builds compile out (owner decision, 2026-11-19); and the
# run passes only if the app reports at least one record applied.
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

PIM_BASE_URL="${PIM_BASE_URL:-}"
PIM_BASE_URL="${PIM_BASE_URL%/}"
PIM_TOKEN="${PIM_TOKEN:-${HEALTHKIT_BRIDGE_TOKEN:-}}"
PIM_OWNER_URL="${PIM_OWNER_URL:-}"
PIM_OWNER_URL="${PIM_OWNER_URL%/}"
if [ -n "$PIM_OWNER_URL" ]; then
  [ -n "$PIM_BASE_URL" ] || { echo "PIM_OWNER_URL needs PIM_BASE_URL: the phone mirrors through PIM's device listener." >&2; exit 1; }
  [ -n "$PIM_TOKEN" ] || { echo "PIM_OWNER_URL needs PIM_TOKEN (or HEALTHKIT_BRIDGE_TOKEN): the mirror routes require the bridge token." >&2; exit 1; }
  case "$PIM_OWNER_URL" in
    https://*) ;;
    *) echo "PIM_OWNER_URL must be https (PIM serves TLS 1.3 on the lane): $PIM_OWNER_URL" >&2; exit 1 ;;
  esac
fi
case "$PIM_BASE_URL" in
  "") ;;
  *127.0.0.1*|*localhost*)
    echo "PIM_BASE_URL is loopback ($PIM_BASE_URL) — the phone cannot reach it. Use the Mac's LAN IP." >&2
    exit 1 ;;
  https://*) ;;
  *) echo "PIM_BASE_URL must be https (PIM serves TLS 1.3 on the lane): $PIM_BASE_URL" >&2; exit 1 ;;
esac

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

# The mirror's test metrics, approved by the owner before the app runs: the
# app stages only `active` metrics (MIRROR_CONTRACT §7). PIM's loopback API is
# server TLS, so pe_device's client (the lane CA, no client certificate) fits.
#
# PIM pushes the approved set to every PE as the HealthKit scope, and a PE with
# a declared scope refuses any type not in it (INGEST_CONTRACT.md, "Scope and
# resync"). So the owner approves the connectivity batch's types too
# (BridgeModel.sendTestBatch: blood pressure, a workout, sleep), or the PE
# refuses that batch as unmapped (RealityEngine_CI e1-rc4-cert-20261120: 400,
# unmapped=3, while the mirror passed).
MIRROR_METRICS='["HKQuantityTypeIdentifierHeartRate","HKQuantityTypeIdentifierStepCount"]'
INGEST_METRICS='["HKCorrelationTypeIdentifierBloodPressure","HKWorkoutTypeIdentifierWorkout","HKCategoryTypeIdentifierSleepAnalysis"]'
pim_owner() { pe_device -H "Authorization: Bearer $PIM_TOKEN" -H 'Content-Type: application/json' "$@"; }
if [ -n "$PIM_OWNER_URL" ]; then
  echo "── PIM owner setup (from Mac): approve the mirror's test metrics"
  pim_owner -X POST "$PIM_OWNER_URL/api/integrations/healthkit/metrics" --data "$(jq -cn '{action:"declare", descriptors:[
    {metric:"HKQuantityTypeIdentifierHeartRate", kind:"quantity", unit:"/min", loinc:"8867-4", fhirCategory:"vital-signs", appleCategory:"Heart", display:"Heart rate"},
    {metric:"HKQuantityTypeIdentifierStepCount", kind:"quantity", unit:"count", loinc:"55423-8", fhirCategory:"activity", appleCategory:"Activity", display:"Steps"},
    {metric:"HKCorrelationTypeIdentifierBloodPressure", kind:"correlation", unit:"mm[Hg]", loinc:"85354-9", fhirCategory:"vital-signs", appleCategory:"Heart", display:"Blood pressure"},
    {metric:"HKWorkoutTypeIdentifierWorkout", kind:"workout", fhirCategory:"activity", appleCategory:"Activity", display:"Workout"},
    {metric:"HKCategoryTypeIdentifierSleepAnalysis", kind:"category", appleCategory:"Sleep", display:"Sleep"}]}')" >/dev/null \
    || { echo "FAIL: PIM refused the test metrics' declaration at $PIM_OWNER_URL"; exit 1; }
  pim_owner -X POST -H 'x-opencommons-owner-approved: true' "$PIM_OWNER_URL/api/integrations/healthkit/metrics" \
    --data "$(jq -cn --argjson m "$MIRROR_METRICS" --argjson i "$INGEST_METRICS" '{action:"add", metrics:($m + $i)}')" >/dev/null \
    || { echo "FAIL: PIM refused the owner's approval of the test metrics at $PIM_OWNER_URL"; exit 1; }
  echo "   approved: $(jq -r --argjson i "$INGEST_METRICS" '. + $i | join(", ")' <<<"$MIRROR_METRICS")"
fi

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
  --arg pimBaseUrl "$PIM_BASE_URL" \
  --arg pimToken "$PIM_TOKEN" \
  '{AUTO_TEST_PUSH:"1", PE_BASE_URL:$peBaseUrl}
   + (if $bridgeToken == "" then {} else {HEALTHKIT_BRIDGE_TOKEN:$bridgeToken, BRIDGE_TOKEN:$bridgeToken} end)
   + (if $pimBaseUrl == "" then {} else {LOCAL_PIM_BASE_URL:$pimBaseUrl} end)
   + (if $pimBaseUrl == "" or $pimToken == "" then {} else {HEALTHKIT_PIM_TOKEN:$pimToken} end)')"
LAUNCH_ARGS=(-autoTestPush 1 -peBaseURL "$PE_BASE_URL")
CONSOLE_LOG=""
CONSOLE_PID=""
if [ -n "$PIM_BASE_URL" ]; then
  # A fresh synchronization, not last run's cached snapshot.
  LAUNCH_ARGS+=(-localPIMBaseURL "$PIM_BASE_URL" -clearPodHydrationCache 1)
  [ -n "$PIM_OWNER_URL" ] && LAUNCH_ARGS+=(-autoTestMirror 1 -autoApproveMirrorBatch 1)
  CONSOLE_LOG="$(mktemp)"
  # --console stays attached for the app's life; it is stopped once the probe
  # line arrives (or the wait below gives up).
  xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE_ID" \
    --environment-variables "$ENV_JSON" \
    "$BUNDLE_ID" -- "${LAUNCH_ARGS[@]}" >"$CONSOLE_LOG" 2>&1 &
  CONSOLE_PID=$!
  # Cleanup only: under set -e a failed kill (the console is usually stopped
  # already) would turn a passing run's exit status into 1.
  trap 'kill "$CONSOLE_PID" 2>/dev/null || true; rm -f "$CONSOLE_LOG" || true' EXIT
else
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" \
    --environment-variables "$ENV_JSON" \
    "$BUNDLE_ID" -- "${LAUNCH_ARGS[@]}"
fi

# The wait covers the app's own delivery schedule: IngestClient tries 4 times
# with a 15 s request timeout and 2/4/8 s between (BridgeConfiguration), about
# 74 s at worst. A 40 s wait failed runs whose first, cold connection took
# longer, while the app was still retrying (RealityEngine_CI regressions
# 20261118T200839Z and 20261118T210559Z; the same launch delivered in seconds
# once the phone's path was warm). It still stops at the first sign of the
# batch.
WAIT_S="${HEALTHKIT_E2E_WAIT_S:-120}"
echo "── Waiting for sensors to land (up to ${WAIT_S}s)"
found=0
for _ in $(seq 1 $((WAIT_S / 2))); do
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

if [ -n "$PIM_BASE_URL" ]; then
  echo "── PIM leg: the app at $PIM_BASE_URL"
  probe=""
  for _ in $(seq 1 30); do
    probe="$(grep -m1 'HealthKitBridge PIM probe' "$CONSOLE_LOG" 2>/dev/null || true)"
    [ -n "$probe" ] && break
    sleep 2
  done
  [ -n "$probe" ] || { kill "$CONSOLE_PID" 2>/dev/null || true; echo "FAIL: the app printed no PIM probe line within 60 s"; exit 1; }
  echo "   ${probe#*HealthKitBridge }"
  case "$probe" in
    *"linked=true synchronized=true"*) echo "PASS: the phone reached PIM and synchronized from it" ;;
    *) kill "$CONSOLE_PID" 2>/dev/null || true
       echo "FAIL: the phone did not link to and synchronize from PIM (on https, check the CA profile is installed and fully trusted, and the PIM token)"; exit 1 ;;
  esac

  if [ -n "$PIM_OWNER_URL" ]; then
    echo "── Mirror leg: the phone previews and applies a synthetic batch"
    outcome=""
    for _ in $(seq 1 45); do
      outcome="$(grep -m1 -E 'HealthKitBridge mirror (applied=|[a-z]+ failed)' "$CONSOLE_LOG" 2>/dev/null || true)"
      [ -n "$outcome" ] && break
      sleep 2
    done
    grep -m1 'HealthKitBridge mirror preview' "$CONSOLE_LOG" 2>/dev/null | sed 's/.*HealthKitBridge /   /' || true
    kill "$CONSOLE_PID" 2>/dev/null || true
    [ -n "$outcome" ] || { echo "FAIL: the app reported no mirror outcome within 90 s (is this a Debug build?)"; exit 1; }
    echo "   ${outcome#*HealthKitBridge }"
    applied="$(sed -n 's/.*mirror applied=\([0-9]*\).*/\1/p' <<<"$outcome")"
    [ "${applied:-0}" -ge 1 ] || { echo "FAIL: the phone's mirror wrote nothing to the Pod"; exit 1; }
    status="$(pe_device "$PIM_OWNER_URL/api/pod/healthkit/status" 2>/dev/null || true)"
    [ -n "$status" ] && echo "   PIM HealthKit status: $(jq -c '.data // . | del(.. | strings | select(test("^https?://")))' <<<"$status" 2>/dev/null | head -c 400)"
    echo "PASS: the phone mirrored $applied record(s) through PIM into the Pod"
  fi
  kill "$CONSOLE_PID" 2>/dev/null || true
fi

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
