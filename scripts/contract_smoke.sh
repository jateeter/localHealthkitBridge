#!/usr/bin/env bash
# Contract smoke for POST /api/integrations/healthkit/ingest and /status.
#
# docs/INGEST_CONTRACT.md is owned by this repo but implemented four times
# (TS Manager PE, C++, LSP, Scala). This script lets the bridge verify the
# contract it depends on against any one of them, without waiting on upstream
# CI. Cross-runtime parity is enforced separately by
# RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts.
#
# Usage:
#   scripts/contract_smoke.sh [PE_BASE_URL]
#
# Env:
#   PE_BASE_URL             default http://127.0.0.1:3004
#   RE_REGISTRY_URL         if set, the first instance's pe_url wins over the default
#   HEALTHKIT_BRIDGE_TOKEN  when set, sent as bridgeToken and the auth arm runs
#
# Exit: 0 all checks passed, 1 a check failed, 2 the PE was unreachable.
set -uo pipefail

INGEST_PATH="/api/integrations/healthkit/ingest"
STATUS_PATH="/api/integrations/healthkit/status"

PE_BASE_URL="${1:-${PE_BASE_URL:-}}"
TOKEN="${HEALTHKIT_BRIDGE_TOKEN:-}"

pass=0; fail=0
ok()   { echo "  PASS: $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail+1)); }
info() { echo "  ..   $*"; }

# ── Resolve the PE ───────────────────────────────────────────────────────────
if [ -z "$PE_BASE_URL" ] && [ -n "${RE_REGISTRY_URL:-}" ]; then
  PE_BASE_URL="$(curl -sf --max-time 5 "$RE_REGISTRY_URL" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    i=json.load(sys.stdin).get("instances",[])
    print(i[0].get("pe_url","") if i else "")
except Exception:
    print("")' 2>/dev/null)"
  [ -n "$PE_BASE_URL" ] && info "resolved PE from registry: $PE_BASE_URL"
fi
PE_BASE_URL="${PE_BASE_URL:-http://127.0.0.1:3004}"
PE_BASE_URL="${PE_BASE_URL%/}"

echo "=== HealthKit ingest contract smoke ==="
echo "PE: $PE_BASE_URL"
echo

if ! curl -sfk --max-time 5 "${PE_BASE_URL}${STATUS_PATH}" >/dev/null 2>&1; then
  echo "PE unreachable at ${PE_BASE_URL}${STATUS_PATH}" >&2
  echo "Start one first, e.g. (cd ../RealityEngine_CI && ./startUniverse.sh)" >&2
  exit 2
fi

# ── /status advertises the canonical endpoints ───────────────────────────────
status_body="$(curl -sk --max-time 10 "${PE_BASE_URL}${STATUS_PATH}")"
check_field() {
  local field="$1" want="$2"
  local got
  got="$(printf '%s' "$status_body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('$field',''))
except Exception: print('')" 2>/dev/null)"
  if [ "$got" = "$want" ]; then ok "status.$field = $want"; else bad "status.$field = '$got' (want '$want')"; fi
}
check_field ingestEndpoint "$INGEST_PATH"
check_field statusEndpoint "$STATUS_PATH"

if printf '%s' "$status_body" | python3 -c 'import json,sys; sys.exit(0 if "tokenConfigured" in json.load(sys.stdin) else 1)' 2>/dev/null; then
  ok "status advertises tokenConfigured"
else
  bad "status missing tokenConfigured"
fi

# ── Batch ingest: canonical three families ───────────────────────────────────
# Values are pre-normalized to [0,1] per the README family tables; the PE must
# not re-normalize. Regions: BP [4320:4324], exercise [4330:4334],
# sleep [4340:4344].
batch_body() {
  local token_line=""
  [ -n "$TOKEN" ] && token_line="\"bridgeToken\": \"$TOKEN\","
  cat <<JSON
{
  "bridgeId": "healthkit-ios-bridge",
  $token_line
  "samples": [
    { "type": "HKCorrelationTypeIdentifierBloodPressure",
      "sourceMappingId": "healthkit:HKCorrelationTypeIdentifierBloodPressure",
      "sourceName": "contract-smoke", "unit": "mm[Hg]",
      "values": [0.60, 0.65, 0.32, 1.0],
      "metadata": { "standard": "SpeziHealthKit", "fhirCode": "85354-9" } },
    { "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
      "sourceMappingId": "healthkit:HKQuantityTypeIdentifierActiveEnergyBurned",
      "sourceName": "contract-smoke", "unit": "kcal",
      "values": [0.25, 0.40, 0.31, 1.0], "metadata": {} },
    { "type": "HKCategoryTypeIdentifierSleepAnalysis",
      "sourceMappingId": "healthkit:HKCategoryTypeIdentifierSleepAnalysis",
      "sourceName": "contract-smoke", "unit": "h",
      "values": [0.70, 0.22, 0.55, 1.0], "metadata": {} }
  ]
}
JSON
}

resp="$(curl -sk --max-time 20 -o /tmp/hk_contract_body.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -X POST "${PE_BASE_URL}${INGEST_PATH}" --data "$(batch_body)")"

case "$resp" in
  200|207) ok "batch ingest status $resp (200 all resolved / 207 partial)" ;;
  400)     ok "batch ingest status 400 — all unmapped; PE has no healthkit mappings configured" ;;
  401)     bad "batch ingest status 401 — token required. Export HEALTHKIT_BRIDGE_TOKEN." ;;
  *)       bad "batch ingest status $resp (want 200/207/400)" ;;
esac

python3 - /tmp/hk_contract_body.json <<'PY'
import json, sys
try:
    b = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  FAIL: response is not JSON ({e})"); sys.exit(1)
errs = []
if not isinstance(b.get("resolved"), list): errs.append("resolved[] missing or not a list")
if not isinstance(b.get("unmapped"), list): errs.append("unmapped[] missing or not a list")
if not isinstance(b.get("success"), bool):  errs.append("success missing or not a bool")
for e in errs: print(f"  FAIL: {e}")
if not errs:
    print(f"  PASS: response shape ok — resolved={len(b['resolved'])} unmapped={len(b['unmapped'])}")
sys.exit(1 if errs else 0)
PY
if [ $? -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi

# ── Auth arm — only meaningful when the PE was launched with a token ─────────
if [ -n "$TOKEN" ]; then
  no_token="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' -X POST "${PE_BASE_URL}${INGEST_PATH}" \
    --data '{"bridgeId":"healthkit-ios-bridge","samples":[]}')"
  if [ "$no_token" = "401" ]; then ok "no-token request rejected 401"; else bad "no-token request returned $no_token (want 401)"; fi
else
  info "HEALTHKIT_BRIDGE_TOKEN unset — skipping auth arm"
  info "(a dummy value does not work: the PE must be launched with the same token)"
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
