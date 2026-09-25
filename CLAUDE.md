# localHealthkitBridge Guidance

Last reviewed: 2026-09-25

See `/Users/johnt/workspace/GitHub/CLAUDE.md` for the integrated application map. Update both this file and the root map when the ingest contract, package layout, or PE integration responsibilities change.

## Role

This repo contains the iOS HealthKit → Perception Engine bridge: a Swift package (`HealthKitBridge`) plus the canonical bridge ↔ PE ingest contract that all four PE runtimes (C++, Lisp, Scala, TypeScript Manager PE) implement.

## Codebase Map

- `Package.swift`: SPM package, iOS 16+ / macOS 13+, no external dependencies.
- `Sources/HealthKitBridge/BridgeConfiguration.swift`: PE base URL, bridgeId/token, retry policy.
- `Sources/HealthKitBridge/HealthKitManager.swift`: authorization, anchored object queries, background delivery.
- `Sources/HealthKitBridge/SampleNormalizer.swift`: README family tables → pre-normalized `[0,1]` 4-vectors.
- `Sources/HealthKitBridge/IngestClient.swift`: batch POST, Bearer auth, exponential backoff, anchorToken round-trip.
- `Sources/HealthKitBridge/AnchorStore.swift`: per-type anchor persistence (UserDefaults, Data-based for testability).
- `Sources/HealthKitBridge/BridgeCoordinator.swift`: wiring of the above.
- `Sources/HealthKitBridge/Models.swift`: payload/response types mirroring the ingest contract.
- `Tests/HealthKitBridgeTests/`: unit coverage.
- `App/`: SwiftUI host app, with `App/UITests/` for the seeded XCUITest leg.
- `scripts/`: contract smoke, simulator / seeded / device e2e, and mobile-Solid phase 0.
- `docs/INGEST_CONTRACT.md`: canonical ingest contract — single source of truth.
- `docs/MIRROR_CONTRACT.md`: how device-side HealthKit data reaches the authoritative POD. **The bridge calls PIM's HTTP API, and PIM, which already holds the Solid session, writes the POD**; the app speaks no Solid. Blood pressure and pulse map to PIM's `vital-signs` domain, and duplicates are prevented by PIM's own reconciliation key. **Proposed** 2026-09-25; decisions D2/D2a/D2b are open.
- `ROADMAP.md`: the M0–M6 plan. v0.1.0 (MVP) was tagged on 2026-09-25; the roadmap records what is open after it.

## Key Commands

```bash
swift build
swift test
PE_BASE_URL=... [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_simulator.sh   # test-batch leg
PE_BASE_URL=... [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_seeded.sh      # seeded XCUITest leg
DEVELOPMENT_TEAM=... [PE_BASE_URL=http://<lan-ip>:...] ./scripts/e2e_device.sh  # physical device leg (M5)
```

## Contract Rules

- `docs/INGEST_CONTRACT.md` is the single source of truth for `POST /api/integrations/healthkit/ingest` and `GET /api/integrations/healthkit/status`. Changes must be mirrored in RealityEngine_CPP, RealityEngine_LSP, RealityEngine_Scala, and the Manager TS PE, and covered by `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`.
- Auth: body `bridgeToken` (alias `token`) OR `Authorization: Bearer` — either channel must match `HEALTHKIT_BRIDGE_TOKEN` when configured. The iOS bridge sends Bearer by default.
- Samples carry pre-normalized 4-element `values`; scalar `value` is a legacy fallback normalized server-side.
- Prefer the instance registry (`re-registry.json`, `instances[].pe_url`) over static ports. Every PE seeds a 7680-dimension vector (`VECTOR_DIMENSION`), which already holds the canonical health regions [4320:4344]; the Manager TS and Scala PEs also grow it on demand for regions beyond that.
- The Manager TS PE additionally accepts a per-bridge `apiKey` from `INTEGRATIONS_CONFIG` ahead of `HEALTHKIT_BRIDGE_TOKEN`. That is a Manager extension, not part of this contract; the bridge must not depend on it.

## Standing rules — authoritative in `../RealityEngine_CI/docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. The table is an index
to the contract, not a copy of it: it names every rule so you know what to look
up, and the contract's wording governs wherever the two differ.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Regenerate a stale `<name>` registry, don't fail it | Each `<name>` registry is a view of the running system. A gate regenerates it and fails only on a disagreement that survives regeneration. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| _CI is the authority | Peripheral repos keep minimal CI that forces local validation; RealityEngine_CI verifies fixes against a live universe. Check its `docs/` before adding CI anywhere else. |
| Name it `CLAUDE.md` | Uppercase, always. On a case-insensitive filesystem `claude.md` is the same inode; dedupe on `st_ino`, never on a resolved path. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |
| Use bash, not zsh | Shell work runs in `/opt/homebrew/bin/bash` (5.x), not zsh or macOS `/bin/bash` 3.2: any loop, unquoted variable, glob or `set --` goes through it with `set -euo pipefail`, and you check the command's exit status, not the pipeline tail. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
