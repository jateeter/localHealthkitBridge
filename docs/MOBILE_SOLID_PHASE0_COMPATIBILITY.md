# Mobile Solid Phase 0 Compatibility Spike

Status: in progress

M5 device validation is no longer on hold for the automated physical-device
path. On 2026-07-24, `scripts/e2e_device.sh` built, installed, and launched the
app on John's iPhone using the current Personal Team provisioning profile
(`DEVELOPMENT_TEAM=YH5P86WUDA`) and delivered the three canonical HealthKit
family sensors to the TypeScript PE over the Mac LAN URL. The remaining M5
background-delivery checklist is manual because it depends on owner permission
prompts and real or manually entered Health samples.

This Phase 0 track remains separate: it researches and validates the Solid Pod
capabilities needed to encapsulate HealthKit-derived information on iPhone
without changing the existing HealthKitBridge ingest contract.

## Scope

Phase 0 proves whether the referenced Swift Solid packages can support the
iPhone side of an OpenCommons Health Solid Pod workflow:

- [`crspybits/SolidAuthSwift`](https://github.com/crspybits/SolidAuthSwift)
  for Solid-OIDC sign-in, WebID/storage discovery, token refresh, and DPoP
  tooling.
- [`crspybits/SolidResourcesSwift`](https://github.com/crspybits/SolidResourcesSwift)
  for authenticated Solid resource requests.

The production `HealthKitBridge` Swift package remains dependency-free in this
phase. The Solid work lives under `Experiments/MobileSolidCompat/`.

## Compatibility model

The iPhone extension should initially behave as a Solid-aware resource owner and
mirror participant, not as a full embedded Solid Community Server. The local and
Docker Solid Community Server deployments remain the full non-iPhone Pod
management surfaces.

```text
iPhone app
  HealthKitBridge package       unchanged
  MobileSolidCompat experiment  Solid sign-in + resource access spike
  encrypted local queue/cache   future phase

localhost/docker
  Solid Community Server        authoritative non-iPhone Solid service
  OpenCommons Health UI         desktop/browser observability and management
```

## Phase 0 acceptance checks

1. Resolve `SolidAuthSwift` and `SolidResourcesSwift` through SwiftPM.
2. Compile `MobileSolidCompatModel`, which keeps path/session/manifest models
   independent from upstream package compatibility.
3. Compile `MobileSolidCompatImportProbe`, which imports `SolidAuthSwiftTools`
   and `SolidResourcesSwift` without pulling UI code into the production bridge.
4. Compile `MobileSolidCompatUI` for an iOS destination, validating the
   `SolidAuthSwiftUI` path separately from core resource access.
5. Authenticate against local CSS with a custom iOS redirect URI.
6. Perform Solid resource CRUD against local/docker CSS:
   - create/ensure app container;
   - PUT a Turtle resource;
   - GET the resource;
   - list the container;
   - DELETE the resource.
7. Run the existing `swift test` suite for `HealthKitBridge`.

## Local CSS configuration shape

Use the same CSS instance already exercised by OpenCommons Health. Example
values for simulator/local development:

```text
SOLID_ISSUER_URL=http://localhost:13000/
SOLID_STORAGE_IRI=http://localhost:13000/alice/
SOLID_PIM_ROOT=health-pim/
SOLID_REDIRECT_URI=opencommons-health:/solid/callback
ALLOW_INSECURE_LOCAL_SOLID_HTTP=true
```

For physical-device or non-loopback LAN testing, plain HTTP must remain
development-only. A later hardening phase must provide HTTPS or an owner-local
tunnel before PHI mirroring is considered acceptable outside local review.

## HealthKit resource containers

Phase 0 establishes path conventions only. Later phases will add the RDF/FHIR
payload mapper and ShEx validation.

```text
health-pim/
  healthkit/
    observations/
    blood-pressure/
    workouts/
    sleep/
  provenance/
  consents/
  sync/
    manifests/
    conflicts/
  audit/
```

## Privacy and observability constraints

- Browser and iPhone observability may show connectivity, counts, resource URLs,
  validation state, mirror state, and sync/audit status.
- Observability must not expose refresh tokens, access tokens, DPoP private
  keys, or identifiable PHI by default.
- Owner approval is required before identifiable HealthKit-derived resources are
  mirrored from iPhone-local state to the local/docker CSS Pod.
- Anonymized release remains separate from Pod mirroring and must continue to
  use explicit owner approval.

## iPhone Pod Management UX

The iPhone app now exposes a first-pass Pod Management screen from the main
`HK Bridge` form under `OpenCommons Pod` -> `Manage owner Pod`.

This UX is deliberately an owner-facing control and observability plane:

- Solid Pod connection settings:
  - issuer URL;
  - storage IRI;
  - OpenCommons PIM root path;
  - custom iOS redirect URI;
  - local-only insecure HTTP toggle for localhost/docker CSS review.
- Owner access and mirror status:
  - authenticated/session state;
  - DPoP enabled/disabled status;
  - token-safe session storage display;
  - HealthKit mirror queue summary;
  - last safe status/error message.
- OpenCommons Health domain visibility:
  - the 11 PIM domains used by the browser application;
  - matching API names;
  - expected FHIR resource family for each domain.
- HealthKit Pod container visibility:
  - observations;
  - blood pressure;
  - workouts;
  - sleep;
  - provenance;
  - consents;
  - sync manifests;
  - conflicts;
  - audit.
- Owner privacy boundary:
  - no access tokens, refresh tokens, DPoP private keys, Epic credentials, or
    raw PHI are displayed;
  - identifiable HealthKit-derived information remains owner-controlled;
  - mirroring and anonymized release are separate owner-approved actions.

The current screen is metadata-backed and staged for live Solid integration.
It does not yet perform Solid-OIDC sign-in or resource CRUD from the production
app target. The next implementation slice should wire this screen to
`SolidAuthSwiftUI` for sign-in and `SolidResourcesSwift` for authenticated
container/resource operations while preserving the existing HealthKitBridge
ingest contract.

## Patient Monitor / Manage UX

The iPhone app now uses a standard three-tab iPhone workflow:

1. **Patient** — the simplified owner-facing OpenCommons Health monitor.
2. **Bridge** — the existing HealthKitBridge PE configuration, authorization,
   delivery, and sync-log controls.
3. **Pod** — the existing Solid Pod connection, container, domain, consent, and
   privacy observability screen.

The Patient tab is intentionally metadata-first and PHI-safe. It presents:

- the OpenCommons Health brand treatment using the heart-record icon and
  green/blue owner-health theme already used by the PIM branding;
- Epic, HealthKit, and Solid Pod source cards;
- all 11 Pod-maintained OpenCommons Health/FHIR domains;
- owner-safe item counts and review state;
- direct navigation to HealthKit Bridge controls and Solid Pod management;
- local iPhone notification controls.

Notification integration is deliberately owner-safe. The app registers a
`PATIENT_MONITOR_STATUS` notification category and can request/send a local
Patient Monitor status notification, but the notification body never includes
diagnoses, values, Epic payloads, HealthKit samples, Pod resource paths, tokens,
refresh tokens, DPoP key material, or other raw PHI.

### Implementation/deployment roadmap

| Phase | Scope | Validation gate | Git checkpoint |
| --- | --- | --- | --- |
| PM-1 | Patient tab with branded source/domain summary and preserved Bridge/Pod tabs | App builds for iOS simulator/generic iOS; UITest verifies Patient, Bridge, and Pod navigation | Feature PR for patient monitor shell |
| PM-2 | Owner-safe notification framework integration | Notification status renders; request/send actions compile against iOS UserNotifications | Same PR if PM-1 validation passes |
| PM-3 | Live SolidAuthSwiftUI sign-in from Pod tab | Device run against local/docker CSS; no tokens/PHI visible in UI logs | Follow-up PR |
| PM-4 | SolidResourcesSwift container list/read/write for metadata manifests | iPhone resource CRUD against local/docker CSS; conflict rows visible | Follow-up PR |
| PM-5 | Epic FHIR import status surfaced from the OpenCommons PIM Pod | Sandbox OAuth/FHIR import writes owner-approved Pod metadata; Patient tab source card reflects Pod-backed status | Follow-up PR |
| PM-6 | Device deployment hardening | Signed device install, HealthKit authorization, background delivery, notifications, and Pod status review on iPhone | Release candidate PR |

## Verification commands

From the repository root:

```bash
swift test
./scripts/mobile-solid-phase0-check.sh
MOBILE_SOLID_RUN_UI_PROBE=true ./scripts/mobile-solid-phase0-check.sh
```

The Phase 0 script keeps the production bridge check, local model tests, and the
experimental Solid import probe separate so an upstream Solid package
compatibility failure does not get confused with a HealthKitBridge regression.

## Current compatibility finding

SwiftPM can resolve the upstream repositories at:

- `SolidAuthSwift` `main` commit `2550e39`
- `SolidResourcesSwift` `main` commit `5c4d86b`

The P0 build blockers are removed by using local patched clones for the
experimental Mobile Solid package:

| Local clone | Upstream commit | Patch |
| --- | --- | --- |
| `Experiments/Vendor/SolidAuthSwift` | `2550e39` | Declares `.macOS(.v10_15)` so `SolidAuthSwiftTools` is compatible with its `JWTKit` dependency, and points `SerdParser` at the local patched clone. |
| `Experiments/Vendor/serd-parser` | `f40bf37` | Adds conditional `Darwin`/`Glibc` imports so `errno`, `strerror`, and `fopen` resolve in the iOS build. |

The experiment package depends on `SolidAuthSwift` through:

```text
.package(path: "../Vendor/SolidAuthSwift")
```

`SolidResourcesSwift` still resolves from upstream `main` at commit `5c4d86b`.

The iOS-destination build path has been split into two probes:

| Probe | Command | Result |
| --- | --- | --- |
| Non-UI resource/auth import | `xcodebuild -scheme MobileSolidCompatImportProbe -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build` | Passes. `SolidAuthSwiftTools` and `SolidResourcesSwift` compile for iOS. |
| UI sign-in import | `xcodebuild -scheme MobileSolidCompatUI -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build` | Passes with the local patched `SolidAuthSwift` and `serd-parser` clones. |

Phase 0 can now proceed to live Solid-OIDC sign-in against local CSS and
authenticated Solid resource CRUD using the iPhone UX path.
