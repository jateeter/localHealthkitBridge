#!/usr/bin/env bash
# Simulator e2e (roadmap M4): build the host app, boot a simulator, launch
# with -autoTestPush, and assert the PE received the three canonical
# families.  The PE may be a live universe instance (pass PE_BASE_URL) or
# any PE implementing docs/INGEST_CONTRACT.md.
#
# Usage:
#   PE_BASE_URL=http://127.0.0.1:3004 [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_simulator.sh
#
# Requires: Xcode with an iOS simulator runtime, xcodegen, jq.
set -euo pipefail

PE_BASE_URL="${PE_BASE_URL:-http://127.0.0.1:3004}"
SIM_NAME="${SIM_NAME:-iPhone 16 Pro}"
BUNDLE_ID="org.energyos.HealthKitBridgeApp"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "── PE preflight: $PE_BASE_URL"
curl -sf "$PE_BASE_URL/api/integrations/healthkit/status" | jq -e '.ingestEndpoint == "/api/integrations/healthkit/ingest"' > /dev/null

echo "── Generate + build"
cd "$REPO_ROOT/App"
xcodegen generate --quiet
xcodebuild -project HealthKitBridgeApp.xcodeproj -scheme HealthKitBridgeApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath build -quiet build

APP_PATH="$(find build/Build/Products -name HealthKitBridgeApp.app -path '*iphonesimulator*' | head -1)"
[ -n "$APP_PATH" ] || { echo "app bundle not found"; exit 1; }

echo "── Boot simulator: $SIM_NAME"
xcrun simctl bootstatus "$SIM_NAME" -b
xcrun simctl install "$SIM_NAME" "$APP_PATH"

echo "── Launch with -autoTestPush (PE=$PE_BASE_URL)"
xcrun simctl launch \
  --terminate-running-process \
  "$SIM_NAME" "$BUNDLE_ID" \
  -autoTestPush 1 \
  -peBaseURL "$PE_BASE_URL" \
  ${HEALTHKIT_BRIDGE_TOKEN:+-bridgeToken "$HEALTHKIT_BRIDGE_TOKEN"}

echo "── Waiting for sensors to land"
for i in $(seq 1 15); do
  sleep 2
  found=$(curl -sf "$PE_BASE_URL/api/sources" | jq '[.sources[] | select(.origin == "healthkit")] | length' 2>/dev/null || echo 0)
  [ "$found" -ge 3 ] && break
done
[ "$found" -ge 3 ] || { echo "FAIL: expected ≥3 healthkit sensors, saw $found"; exit 1; }

curl -sf "$PE_BASE_URL/api/sources" \
  | jq -r '.sources[] | select(.origin == "healthkit") | "  \(.sensorId) @ [\(.region.offset):\(.region.offset + .region.length)] = \(.lastValue)"'
echo "PASS: $found healthkit sensor sources live on the PE"
