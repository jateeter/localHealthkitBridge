#!/usr/bin/env bash
# Seeded simulator e2e (roadmap M4): build the app + UI-test bundle, run
# SeededFlowUITests — which launches with -seedHealthData, accepts the
# HealthKit permission sheet, seeds nominal samples via the DEBUG seeder,
# and waits for the app to log a delivered batch — then assert the PE's
# healthkit sensor sources changed as a result.
#
# Usage:
#   PE_BASE_URL=http://127.0.0.1:3004 [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_seeded.sh
#
# The PE may be a live universe instance (pass PE_BASE_URL from
# re-registry.json instances[].pe_url) or any PE implementing
# docs/INGEST_CONTRACT.md.  For a meaningful assertion run against a PE
# without pre-existing healthkit sensors, or after the test-batch leg with
# different values.
#
# Requires: Xcode with an iOS simulator runtime, xcodegen, jq.
set -euo pipefail

PE_BASE_URL="${PE_BASE_URL:-http://127.0.0.1:3004}"
# Prefer the newest Pro-class device; iPhone 17 Pro is the floor.
SIM_NAME="${SIM_NAME:-$(xcrun simctl list devices available \
  | grep -oE 'iPhone (1[7-9]|[2-9][0-9])( Pro( Max)?| Air)?' \
  | sort -Vr | head -1)}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
BUNDLE_ID="org.energyos.HealthKitBridgeApp"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "── PE preflight: $PE_BASE_URL"
curl -sf "$PE_BASE_URL/api/integrations/healthkit/status" | jq -e '.ingestEndpoint == "/api/integrations/healthkit/ingest"' > /dev/null

before="$(curl -sf "$PE_BASE_URL/api/sources" \
  | jq -c '[.sources[] | select(.origin == "healthkit")] | sort_by(.sensorId)')"

echo "── Generate + build"
cd "$REPO_ROOT/App"
xcodegen generate --quiet
xcodebuild -project HealthKitBridgeApp.xcodeproj -scheme HealthKitBridgeApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath build -quiet build-for-testing

echo "── Boot simulator: $SIM_NAME"
xcrun simctl bootstatus "$SIM_NAME" -b
# Fresh install so the HealthKit permission sheet appears deterministically.
xcrun simctl uninstall "$SIM_NAME" "$BUNDLE_ID" 2>/dev/null || true

echo "── Run SeededFlowUITests (PE=$PE_BASE_URL)"
TEST_RUNNER_PE_BASE_URL="$PE_BASE_URL" \
TEST_RUNNER_HEALTHKIT_BRIDGE_TOKEN="${HEALTHKIT_BRIDGE_TOKEN:-}" \
xcodebuild test-without-building \
  -project HealthKitBridgeApp.xcodeproj -scheme HealthKitBridgeApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath build -quiet \
  -only-testing:HealthKitBridgeUITests/SeededFlowUITests

echo "── Asserting healthkit sensors on the PE"
after="$(curl -sf "$PE_BASE_URL/api/sources" \
  | jq -c '[.sources[] | select(.origin == "healthkit")] | sort_by(.sensorId)')"
count="$(jq 'length' <<< "$after")"
[ "$count" -ge 3 ] || { echo "FAIL: expected ≥3 healthkit sensors, saw $count"; exit 1; }
if [ "$after" = "$before" ]; then
  echo "FAIL: healthkit sensors unchanged by the seeded run (stale PE state?)"
  exit 1
fi

jq -r '.[] | "  \(.sensorId) @ [\(.region.offset):\(.region.offset + .region.length)] = \(.lastValue)"' <<< "$after"
echo "PASS: $count healthkit sensors live and updated by the seeded run"
