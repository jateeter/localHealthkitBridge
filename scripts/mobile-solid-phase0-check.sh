#!/usr/bin/env bash
# Phase 0 Mobile Solid compatibility checks. This script intentionally keeps the
# production HealthKitBridge package check separate from the experimental Swift
# Solid dependency check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPERIMENT_DIR="$REPO_ROOT/Experiments/MobileSolidCompat"

echo "── HealthKitBridge regression suite"
cd "$REPO_ROOT"
swift test

echo "── MobileSolidCompatModel iOS build"
cd "$EXPERIMENT_DIR"
xcodebuild -scheme MobileSolidCompatModel \
  -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO \
  -quiet build

echo "── MobileSolidCompatImportProbe iOS build"
xcodebuild -scheme MobileSolidCompatImportProbe \
  -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO \
  -quiet build

if [ "${MOBILE_SOLID_RUN_UI_PROBE:-false}" = "true" ]; then
  echo "── MobileSolidCompatUI iOS build"
  xcodebuild -scheme MobileSolidCompatUI \
    -destination generic/platform=iOS \
    CODE_SIGNING_ALLOWED=NO \
    -quiet build
fi

cat <<'SUMMARY'

Phase 0 automated checks completed.

Manual checks still required:
  1. Sign in to local CSS with SolidAuthSwiftUI.
  2. Use SolidResourcesSwift to PUT/GET/list/DELETE a Turtle resource.
SUMMARY
