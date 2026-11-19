#!/usr/bin/env bash
# A Release build of the app carries none of the Debug-only test hooks
# (RealityEngine_CI#808, owner decision 2026-11-19). The unattended mirror
# approval (-autoApproveMirrorBatch) writes to the owner's Pod without a tap,
# so it may exist only in Debug builds, which the device e2e uses; the same
# holds for the synthetic mirror batch and the Health data seeder.
#
# Usage: scripts/check_release_flags.sh path/to/HealthKitBridgeApp.app
set -euo pipefail

APP="${1:?usage: $0 path/to/HealthKitBridgeApp.app (a Release build)}"
[ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 2; }

FLAGS=(autoApproveMirrorBatch autoTestMirror seedHealthData)
found=0
while IFS= read -r -d '' f; do
  for flag in "${FLAGS[@]}"; do
    # grep -c reads to the end: grep -q would stop strings with SIGPIPE, and
    # under pipefail that reads as "no match".
    if [ "$(strings "$f" 2>/dev/null | grep -c "$flag" || true)" -gt 0 ]; then
      echo "FAIL: $flag is in ${f#"$APP"/}: a Debug-only hook reached a Release build" >&2
      found=1
    fi
  done
done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)

[ "$found" = 0 ] || exit 1
echo "PASS: no Debug-only hook (${FLAGS[*]}) in $(basename "$APP")"
