# localHealthkitBridge — Roadmap to MVP (v0.1.0)

Last reviewed: 2026-08-09

## Where the project stands

**This repo ships a Swift package and an iOS host app, and is in the MVP.**

It was documentation-only when this roadmap was written on 2026-07-13. That
stopped being true with M1, and the claim survived here long after the code
did — through M3, M4 and M7. It is corrected rather than quietly deleted
because a stale status line is how a reader concludes the opposite of the
truth.

| Here now | |
|---|---|
| `Package.swift` + `Sources/HealthKitBridge/` | 7 modules — configuration, anchored HK queries, normalization, ingest client, anchor persistence |
| `Tests/HealthKitBridgeTests/` | 5 suites, run by `swift test` |
| `App/` | SwiftUI host app + `App/UITests/` |
| `scripts/` | 5 scripts: contract smoke, simulator e2e, seeded e2e, device e2e, mobile-Solid phase 0 |
| `.github/workflows/ci.yml` | `swift build` + `swift test`, plus an unsigned generic-iOS build and a simulator Patient-navigation UI test, on `macos-15` |

### Scope status

The integrated RealityEngine MVP includes **both** this bridge and
`OpenCommons-Health---Personal-Information-Management`. This app is in scope,
not deferred — recorded as G4 in `RealityEngine_CI/docs/MVP_ROADMAP.md`, with
the ownership split and the authority rule (the SCS POD is authoritative)
summarised under *Where the data lives* below.

The bridge's simulator leg is also a stage of the RealityEngine regression
local lane and passes green against a live C++ PE.

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

### Where the data lives (decided 2026-08-09)

Both this bridge and `OpenCommons-Health---Personal-Information-Management`
are in the integrated RealityEngine MVP.

| Component | Owns |
|---|---|
| PIM | the **Solid Community Server**, and the POD(s) it maintains |
| **This repo** | a device-side pod, **mirrored into** the POD in the SCS |

**The authoritative information repository is the POD(s) within the Solid
Community Server.** This repo's pod is a mirror source, not a second system of
record. Where the two disagree the SCS POD is correct, which is what makes
`MobilePodModel`'s `.conflict` a resolvable state rather than an ambiguous one:
resolution is toward the SCS copy.

Two consequences for work here:

- A successful device-side write is not durable until it has mirrored.
  `pendingMirror` is a real intermediate state, not a display detail.
- Nothing downstream should read the device pod as authoritative.

PE ingest is unaffected — the bridge continues to post normalized vectors to
`/api/integrations/healthkit/ingest`. That path feeds the perceptual space; the
pod mirror is about durable ownership of the underlying observations. They are
separate concerns and both stay.

The boundary is recorded once, in `RealityEngine_CI/docs/MVP_ROADMAP.md` (G4),
and deliberately not restated in detail here.

## Milestones

### M0 — Contract reconciliation ✅

`docs/INGEST_CONTRACT.md` is the canonical schema, and per-engine parity is
enforced by `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`.
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

### M1 — Package scaffold + CI ✅
- `Package.swift` (SpeziHealthKit dependency; **no** SpeziCareKit yet), `Sources/HealthKitBridge/`,
  `Tests/HealthKitBridgeTests/`.
- GitHub Actions: `swift build` + `swift test` on macOS runner; SwiftLint.

### M2 — Core modules ✅
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

### M4 — Simulator e2e (1–2 days) ✅ 2026-07-14

`scripts/e2e_simulator.sh` passes against both the TS Manager PE and the
native C++ PE (`bin/perception_engine_server` + `integrations.healthkit-e2e.json`):
identical normalized vectors at [4320:4344] on both engines. Simulator floor
is iPhone 17 Pro (script auto-picks the newest Pro-class device).

Seeded leg ✅ 2026-07-14: `scripts/e2e_seeded.sh` runs
`SeededFlowUITests` — launch with `-seedHealthData`, accept the combined
read+write HealthKit sheet (bottom `UIA.Health.Allow.Button` on iOS 26),
DEBUG-only `DebugSeeder` writes nominal samples, anchored observers deliver,
then the script asserts the PE's healthkit sensors changed. Passes against
the TS PE and the universe C++ PE (`startUniverse.sh --no-openclaw`).
Blood-pressure correlation type removed from the read-authorization set
(HealthKit rejects authorization requests for correlation types).

RE transition ✅ 2026-07-14: new corpus machine
`RealityEngine_Machines/machines/domains/health-personal/HealthKitVitalsMonitor.json`
(gte, input [4320:4324], output [4304:4308]) classifies bridge BP readings
into NOMINAL/HYPERTENSIVE/CRISIS; clinical cutoffs live in element
`threshold`s (engines binarize input and pattern at each element's threshold
before gte). Verified on cpp-1/lsp-1/scala-1: seeded reading
[0.6,0.65,0.32,1] fires exactly `hk-vitals-nominal` → [1,0,0,0] on all
three. Universe healthkit wiring enabled in
`RealityEngine_CI/config/integrations.example.json` (bridge `enabled: true`
+ per-type mappings at the contract regions).

### M5 — Device e2e + background delivery (2–3 days) — tooling ready 2026-07-15
- Physical iPhone + Apple Watch over Mac LAN IP; token auth enabled.
- Validate background delivery wakes + posts with app backgrounded/killed;
  TTL expiry and re-arm behavior; silent-failure logging (>30 min alert rule).

Silent-failure logging ✅ 2026-07-15: `BridgeCoordinator.startSilenceWatchdog`
emits one `.alert` sync-log event per silence episode after the threshold
(default 30 min; app arms it with observers, `-silenceThresholdMinutes`
overrides); the next successful delivery re-arms it. Covered by
`BridgeCoordinatorTests` (25/25 package tests green).

Device leg tooling ✅ 2026-07-15: `scripts/e2e_device.sh` — discovers a
paired iPhone via `devicectl`, refuses loopback PE URLs (defaults to the
Mac's LAN IP), signs with `DEVELOPMENT_TEAM`, installs + launches with
`-autoTestPush` + token, asserts PE sensors, then prints the manual
background-delivery checklist (backgrounded/killed wake, TTL re-arm,
silent-failure alert).

Automated device leg ✅ 2026-07-24: ran `scripts/e2e_device.sh` on "John's
iPhone" (iOS 26.6) against LAN PE `http://192.168.1.194:3004` (TS Manager
PE, CPP healthkit-spezi registry). Signed with Apple Team `YH5P86WUDA`
(from the signing cert's `OU`; automatic provisioning via
`-allowProvisioningUpdates`). Build + sign + install + launch
(`-autoTestPush`) succeeded and all three canonical families landed on the
PE — `healthkit.blood-pressure` [4320:4324], `healthkit.exercise`
[4330:4334], `healthkit.sleep` [4340:4344] (TTL 900s). Token-auth verified
against the PE from the Mac (batch `samples[]` body: no-token → 401,
bad-bearer → 401, good-bearer → 200) with `HEALTHKIT_BRIDGE_TOKEN` set.

Remaining M5 (manual, needs a physical operator at the device): HealthKit
authorization + observers, backgrounded/killed background-delivery wake,
TTL re-arm after expiry, and the silent-failure watchdog alert (break the
token / stop the PE). The `devicectl` launch also requires the iPhone to be
**unlocked** — a locked screen fails with `FBSOpenApplicationErrorDomain`
error 7 ("device was not, or could not be, unlocked").

### M6 — Release hygiene (1–2 days)
- README truth pass against shipped behavior; tag `v0.1.0`; optional TestFlight.

### M7 — Patient Monitor / Manage iPhone UX ✅ 2026-07-28

The iPhone app now has a patient-first OpenCommons Health monitor as its main
tab while keeping the original technical visualizations available through
standard iPhone tab navigation:

- **Patient**: branded OpenCommons Health dashboard for Epic, HealthKit, and
  owner Solid Pod source status; all 11 Pod-maintained FHIR-aligned domains;
  owner-safe counts and review indicators.
- **Bridge**: existing HealthKitBridge configuration, authorization, test
  batch, PE status, and sync-log workflow.
- **Pod**: existing Solid Pod issuer/storage/redirect settings, owner access,
  mirror state, 11-domain visibility, HealthKit containers, consent, conflicts,
  and audit observability.

Notification integration is in place for the Patient Monitor. The app registers
a `PATIENT_MONITOR_STATUS` category, requests local notification authorization,
and sends a PHI-safe local status notification that never includes diagnoses,
values, raw HealthKit samples, Epic payloads, Pod paths, or credential material.

Deployment/verification gates for this slice, and where each is enforced:

| Gate | Enforced by |
|---|---|
| Swift package build/test green | CI `test` job — `swift build` + `swift test` |
| `HealthKitBridgeApp` builds for simulator and generic iOS | CI `app` job — `xcodegen generate`, then unsigned `generic/platform=iOS` build and a simulator build |
| UI automation proves the Patient tab and preserved Bridge/Pod navigation | CI `app` job — `SeededFlowUITests/testPatientMonitorNavigationSurfacesExistingScreens` |
| HealthKit authorization, background delivery, local notifications | **Manual, physical device.** `scripts/e2e_device.sh` plus the M5 checklist |

The first three were aspirational until the `app` job existed — CI ran only
`swift build`/`swift test`, so neither the app target nor the UI automation was
built. They now gate every PR.

The device gate cannot be automated on a hosted runner: it needs a paired
iPhone, a signing identity, and a human to accept the HealthKit sheet. The
seeded UI test (`testSeededDeliveryReachesPE`) is likewise operator-run — it
drives the permission sheet and needs a live PE — so CI runs only the
navigation test from that bundle.

`scripts/contract_smoke.sh` verifies the ingest contract this repo owns against
any running PE, independent of upstream CI.

**Total: ~11–16 working days.** M1/M2 can start in parallel with M0 (only the
auth decision blocks `IngestClient`).

## Post-MVP (v0.2+)
- CareKit adherence sync (localAIStack Phase 4a machine at [194:202] first).
- localAI band-mode target (raw values → PE band normalization at [186:190]).
- Registry-aware PE discovery (`re-registry.json`) instead of a static base URL.
- FHIR provenance export / EHR path.
