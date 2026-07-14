# localHealthkitBridge — Roadmap to MVP (v0.1.0)

Last reviewed: 2026-07-13

## Where the project stands

This repo is currently **documentation only**: `README.md` (a thorough spec covering
architecture, HK types, normalization, payloads, auth, and per-runtime connection),
an MIT `LICENSE`, and an Xcode/SPM `.gitignore`. There is **no Swift code yet** —
no `Package.swift`, no sources, no tests, no CI.

The server side the bridge talks to is **already built and is not MVP work**:

| Surface | Status |
|---|---|
| TS PE (Manager) `POST /api/integrations/healthkit/ingest` | ✅ `perception-engine/backend/src/server.ts` + `integrations/adapters/HealthKitBridge.ts` + unit tests |
| C++ PE ingest + status | ✅ `RealityEngine_CPP/src/perception_engine_server.cpp:304` |
| Lisp PE ingest + status | ✅ `RealityEngine_LSP/src/perception-service.lisp:1503` |
| Scala PE ingest + status | ✅ `PerceptionRoutes.scala:816` |
| Example configs / payload fixtures / e2e scripts | ✅ per runtime (`integrations.healthkit-spezi.example.json`, `e2e_healthkit_spezi.sh`) |
| Corpus machines consuming HK regions (~[4300:4560]) | ✅ `RealityEngine_Machines/machines/domains/health-personal/` |
| localAIStack health domain (band sensors [186:194], chat context, simulator) | ✅ Phases 1–3 complete |

## Contract drift that must be reconciled first (M0)

Three descriptions of the ingest contract currently disagree:

1. **README / native runtimes** — pre-normalized 4-element `values`, auth via body
   `bridgeToken` (`HEALTHKIT_BRIDGE_TOKEN`; Bearer header explicitly *not* accepted),
   mapping key `healthkit:<type>[:<sourceName>]`, regions [4320:4344].
2. **TS PE (Manager)** — requires `bridgeId` + `samples[]`, auth via
   `Authorization: Bearer` checked against the integration registry (`checkBridgeAuth`);
   supports `anchorToken` echo. No body-token path.
3. **localAIStack `HEALTH_INTEGRATION_ROADMAP.md` Phase 4c** — different schema
   (`hkTypeIdentifier`, raw `value`, no auth), server-side band normalization,
   regions [186:190], target port 3004.

MVP decision: **the native-runtime contract (1) is canonical** — it is implemented
three times and matches this README. The TS PE auth mismatch and the localAI raw-value
variant are reconciled in M0 below. Minor doc fix: README lists Scala PE default port
5000; the universe spawns `scala-1` PE at 5100 (registry is the source of truth).

## MVP definition

A read-only iOS app (thin SwiftUI host + `HealthKitBridge` SPM package) that:

- requests read-only HK authorization for the three README families
  (blood pressure, exercise, sleep),
- uses anchored object queries with persisted anchors + background delivery
  (no duplicate replay),
- normalizes each family to its 4-element `[0,1]` vector per the README tables,
- batch-posts to a **configurable PE base URL** with `bridgeId` + `bridgeToken`,
  with 3-attempt exponential backoff retry,
- surfaces last-sync/status from `GET /api/integrations/healthkit/status`,
- is verified e2e: simulator → local universe (TS PE **and** one native PE),
  then physical iPhone/Watch over LAN.

**Out of scope for v0.1.0:** CareKit sync (Phase 4a), FHIR export, HK write access,
historical backfill beyond anchor init, in-app chat UI, multi-device identity.

## Milestones

### M0 — Contract reconciliation (1–2 days)
- Write `docs/INGEST_CONTRACT.md` as the single canonical schema (batch body:
  `bridgeId`, `bridgeToken`, `samples[{type, sourceName?, unit, values[4], metadata}]`,
  optional `anchorToken`).
- Align TS PE auth: accept body `bridgeToken` alongside registry Bearer (or vice
  versa everywhere) — one small server change, decided once.
- Add a per-engine contract test to `RealityEngine_Machines/tests/integration/`
  (mirroring `machine-json-listing.spec.ts`) that POSTs the fixture payloads from
  `healthkit-spezi-payloads.example.json` to all registered PEs and asserts
  `resolved` / `unmapped` / status-code parity.
- Fix README port table + note that `re-registry.json` supersedes static ports.

### M1 — Package scaffold + CI (1 day)
- `Package.swift` (SpeziHealthKit dependency; **no** SpeziCareKit yet), `Sources/HealthKitBridge/`,
  `Tests/HealthKitBridgeTests/`.
- GitHub Actions: `swift build` + `swift test` on macOS runner; SwiftLint.

### M2 — Core modules (3–4 days)
- `BridgeConfiguration.swift` — PE base URL, bridgeId/token, retry policy;
  from Info.plist / scheme env.
- `HealthKitManager.swift` — authorization, `HKAnchoredObjectQuery` per type,
  anchor persistence (UserDefaults), `enableBackgroundDelivery`.
- `SampleNormalizer.swift` — README family tables (BP 0–200/0–120 mmHg, exercise
  0–3000 kcal / 0–120 min / 0–10000 steps, sleep 0–10 h + REM/core fractions),
  raw values retained in `metadata`.
- `IngestClient.swift` — batch POST, token, backoff (2s/4s/8s), `anchorToken`
  round-trip; `URLProtocol`-mocked tests.
- Unit tests: normalizer boundaries, anchor persistence, retry/auth failure paths.

### M3 — Host app (2 days) ✅ 2026-07-14

Shipped as `App/` (XcodeGen `project.yml` + SwiftUI sources; `.xcodeproj`
is generated, not committed). Launch args `-peBaseURL/-bridgeToken/-autoTestPush`
override settings for scripted runs. `scripts/e2e_simulator.sh` covers the
simulator half of M4: build → boot → launch → assert healthkit sensors on
the PE (verified against the contract-aligned TS PE).

- Minimal SwiftUI app embedding the package: authorize button, settings
  (PE URL, token), sync log, status view driven by `/status`.
- HealthKit + Background Modes capabilities, privacy strings per README.

### M4 — Simulator e2e (1–2 days)
- Simulator against the local universe (`startUniverse.sh`), PE at `127.0.0.1`.
- Seed Health data in simulator; verify PE `resolved[]`, sensor TTLs, and an RE
  transition in a `health-personal` machine (e.g. SleepQualityMonitor at [4310:4324]).
- Cross-check payload byte-parity with the runtime fixture files.

### M5 — Device e2e + background delivery (2–3 days)
- Physical iPhone + Apple Watch over Mac LAN IP; token auth enabled.
- Validate background delivery wakes + posts with app backgrounded/killed;
  TTL expiry and re-arm behavior; silent-failure logging (>30 min alert rule).

### M6 — Release hygiene (1–2 days)
- README truth pass against shipped behavior; tag `v0.1.0`; optional TestFlight.

**Total: ~11–16 working days.** M1/M2 can start in parallel with M0 (only the
auth decision blocks `IngestClient`).

## Post-MVP (v0.2+)
- CareKit adherence sync (localAIStack Phase 4a machine at [194:202] first).
- localAI band-mode target (raw values → PE band normalization at [186:190]).
- Registry-aware PE discovery (`re-registry.json`) instead of a static base URL.
- FHIR provenance export / EHR path.
